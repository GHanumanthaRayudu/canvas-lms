require File.expand_path(File.dirname(__FILE__) + '/common')

describe "conversations" do
  it_should_behave_like "in-process server selenium tests"

  prepend_before(:each) do
    Setting.set("file_storage_test_override", "local")
  end

  before(:each) do
    course_with_teacher_logged_in

    term = EnrollmentTerm.new :name => "Super Term"
    term.root_account_id = @course.root_account_id
    term.save!

    @course.update_attributes! :enrollment_term => term

    @user.watched_conversations_intro
    @user.save
  end

  def new_conversation(reload=true)
    if reload
      get "/conversations"
      keep_trying_until { driver.find_element(:id, "create_message_form") }
    else
      driver.find_element(:id, "action_compose_message").click
    end

    @input = find_with_jquery("#create_message_form input:visible")
    @browser = find_with_jquery("#create_message_form .browser:visible")
    @level = 1
    @elements = nil
  end

  def browse_menu
    @browser.click
    keep_trying_until {
      find_all_with_jquery('.autocomplete_menu:visible .list').size.should eql(@level)
    }
    wait_for_animations
  end

  def browse(*names)
    name = names.shift
    @level += 1
    prev_elements = elements
    element = prev_elements.detect { |e| e.last == name } or raise "menu item does not exist"

    element.first.click
    wait_for_ajaximations(150)
    keep_trying_until {
      find_all_with_jquery('.autocomplete_menu:visible .list').size.should eql(@level)
    }

    @elements = nil
    elements

    if names.present?
      browse(*names, &Proc.new)
    else
      yield
    end

    @elements = prev_elements
    @level -= 1
    @input.send_keys(:arrow_left)
    wait_for_animations
  end

  def elements
    @elements ||= driver.execute_script("return $('.autocomplete_menu:visible .list').last().find('ul').last().find('li').toArray();").map { |e|
      [e, (e.find_element(:tag_name, :b).text rescue e.text)]
    }
  end

  def menu
    elements.map(&:last)
  end

  def toggled
    elements.select { |e| e.first.attribute('class') =~ /(^| )on($| )/ }.map(&:last)
  end

  def click(name)
    element = elements.detect { |e| e.last == name } or raise "menu item does not exist"
    element.first.click
  end

  def toggle(name)
    element = elements.detect { |e| e.last == name } or raise "menu item does not exist"
    element.first.find_element(:class, 'toggle').click
  end

  def tokens
    find_all_with_jquery("#create_message_form .token_input li div").map(&:text)
  end

  def search(text, input_id="recipients")
    @input.send_keys(text)
    keep_trying_until do
      driver.execute_script("return $('\##{input_id}').data('token_input').selector.last_search") == text
    end
    @elements = nil
    yield
    @elements = nil
    if input_id == "recipients"
      @input.send_keys(*@input.attribute('value').size.times.map { :backspace })
      keep_trying_until do
        driver.execute_script("return $('.autocomplete_menu:visible').toArray();").size == 0 ||
          driver.execute_script("return $('\##{input_id}').data('token_input').selector.last_search") == ''
      end
    end
  end

  def submit_message_form(opts={})
    opts[:message] ||= "Test Message"
    opts[:attachments] ||= []
    opts[:add_recipient] = true unless opts.has_key?(:add_recipient)
    opts[:group_conversation] = true unless opts.has_key?(:group_conversation)

    if opts[:add_recipient] && browser = find_with_jquery("#create_message_form .browser:visible")
      browser.click
      wait_for_ajaximations(150)
      find_with_jquery('.selectable:visible').click
      wait_for_ajaximations(150)
      find_with_jquery('.toggleable:visible .toggle').click
      wait_for_ajaximations
      driver.find_elements(:css, '.token_input ul li').length.should > 0
      find_with_jquery("#create_message_form input:visible").send_keys("\t")
    end

    find_with_jquery("#create_message_form textarea").send_keys(opts[:message])

    opts[:attachments].each_with_index do |fullpath, i|
      driver.find_element(:id, "action_add_attachment").click

      keep_trying_until {
        find_all_with_jquery("#create_message_form .file_input:visible")[i]
      }.send_keys(fullpath)
    end

    if opts[:media_comment]
      driver.execute_script <<-JS
        $("#media_comment_id").val(#{opts[:media_comment].first.inspect})
        $("#media_comment_type").val(#{opts[:media_comment].last.inspect})
        $("#create_message_form .media_comment").show()
        $("#action_media_comment").hide()
      JS
    end

    group_conversation_link = driver.find_element(:id, "group_conversation")
    group_conversation_link.click if group_conversation_link.displayed? && opts[:group_conversation]

    expect {
      driver.find_element(:id, "create_message_form").submit
      wait_for_ajaximations
    }.to change(ConversationMessage, :count).by(opts[:group_conversation] ? 1 : find_all_with_jquery('.token_input li').size)

    if opts[:group_conversation]
      message = ConversationMessage.last
      driver.find_element(:id, "message_#{message.id}").should_not be_nil
      message
    end
  end

  def get_messages
    get "/conversations"
    elements = nil
    keep_trying_until {
      elements = find_all_with_jquery("#conversations > ul > li:visible")
      elements.size == 1
    }
    elements.first.click
    wait_for_ajaximations
    driver.find_elements(:css, "div#messages ul.messages > li")
  end

  def delete_selected_messages(confirm_conversation_deleted = true)
    orig_size = find_all_with_jquery("#conversations > ul > li:visible").size

    wait_for_animations
    delete = driver.find_element(:id, 'action_delete')
    delete.should be_displayed
    delete.click
    driver.switch_to.alert.accept

    if confirm_conversation_deleted
      keep_trying_until {
        find_all_with_jquery("#conversations > ul > li:visible").size.should eql(orig_size - 1)
      }
    end
  end

  context "conversation loading" do
    it "should load all conversations" do
      @me = @user
      num = 51
      num.times { conversation(@me, user) }
      get "/conversations"
      keep_trying_until do
        elements = find_all_with_jquery("#conversations > ul > li:visible")
        elements.last.location_once_scrolled_into_view
        elements.size.should == num
      end
    end

    it "should properly clear the identity header when conversations are read" do
      enable_cache do
        @me = @user
        5.times { conversation(@me, user).update_attribute(:workflow_state, 'unread') }
        get '/conversations'
        driver.find_element(:css, '.conversations li:first-child').click
        get '/conversations'
        driver.find_element(:css, '.unread-messages-count').text.should eql '4'
      end
    end
  end

  context "recipient finder" do
    before (:each) do
      @course.update_attribute(:name, "the course")
      @course.default_section.update_attribute(:name, "the section")
      @other_section = @course.course_sections.create(:name => "the other section")

      @s1 = User.create(:name => "student 1")
      @course.enroll_user(@s1)
      @s2 = User.create(:name => "student 2")
      @course.enroll_user(@s2, "StudentEnrollment", :section => @other_section)

      @group = @course.groups.create(:name => "the group")
      @group.users << @s1 << @user

      new_conversation
    end

    it "should allow browsing" do
      browse_menu

      menu.should eql ["the course", "the group"]
      browse "the course" do
        menu.should eql ["Everyone", "Teachers", "Students", "Course Sections", "Student Groups"]
        browse("Everyone") { menu.should eql ["Select All", "nobody@example.com", "student 1", "student 2"] }
        browse("Teachers") { menu.should eql ["nobody@example.com"] }
        browse("Students") { menu.should eql ["Select All", "student 1", "student 2"] }
        browse "Course Sections" do
          menu.should eql ["the other section", "the section"]
          browse "the other section" do
            menu.should eql ["Students"]
            browse("Students") { menu.should eql ["student 2"] }
          end
          browse "the section" do
            menu.should eql ["Everyone", "Teachers", "Students"]
            browse("Everyone") { menu.should eql ["Select All", "nobody@example.com", "student 1"] }
            browse("Teachers") { menu.should eql ["nobody@example.com"] }
            browse("Students") { menu.should eql ["student 1"] }
          end
        end
        browse "Student Groups" do
          menu.should eql ["the group"]
          browse("the group") { menu.should eql ["Select All", "nobody@example.com", "student 1"] }
        end
      end
      browse("the group") { menu.should eql ["Select All", "nobody@example.com", "student 1"] }
    end

    it "should check already-added tokens when browsing" do
      browse_menu

      browse("the group") do
        menu.should eql ["Select All", "nobody@example.com", "student 1"]
        toggle "student 1"
        tokens.should eql ["student 1"]
      end

      browse("the course") do
        browse("Everyone") do
          toggled.should eql ["student 1"]
        end
      end
    end

    it "should have working 'select all' checkboxes in appropriate contexts" do
      browse_menu

      browse "the course" do
        toggle "Everyone"
        toggled.should eql ["Everyone", "Teachers", "Students"]
        tokens.should eql ["the course: Everyone"]

        toggle "Everyone"
        toggled.should eql []
        tokens.should eql []

        toggle "Students"
        toggled.should eql ["Students"]
        tokens.should eql ["the course: Students"]

        toggle "Teachers"
        toggled.should eql ["Everyone", "Teachers", "Students"]
        tokens.should eql ["the course: Everyone"]

        toggle "Teachers"
        toggled.should eql ["Students"]
        tokens.should eql ["the course: Students"]

        browse "Teachers" do
          toggle "nobody@example.com"
          toggled.should eql ["nobody@example.com"]
          tokens.should eql ["the course: Students", "nobody@example.com"]

          toggle "nobody@example.com"
          toggled.should eql []
          tokens.should eql ["the course: Students"]
        end
        toggled.should eql ["Students"]

        toggle "Teachers"
        toggled.should eql ["Everyone", "Teachers", "Students"]
        tokens.should eql ["the course: Everyone"]

        browse "Students" do
          toggle "Select All"
          toggled.should eql []
          tokens.should eql ["the course: Teachers"]

          toggle "student 1"
          toggle "student 2"
          toggled.should eql ["Select All", "student 1", "student 2"]
          tokens.should eql ["the course: Everyone"]
        end
        toggled.should eql ["Everyone", "Teachers", "Students"]

        browse "Everyone" do
          toggle "student 1"
          toggled.should eql ["nobody@example.com", "student 2"]
          tokens.should eql ["nobody@example.com", "student 2"]
        end
        toggled.should eql []
      end
    end

    it "should allow searching" do
      search("t") do
        menu.should eql ["the course", "the group", "the other section", "student 1", "student 2"]
      end
    end

    it "should omit already-added tokens when searching" do
      search("student") do
        menu.should eql ["student 1", "student 2"]
        click "student 1"
      end
      tokens.should eql ["student 1"]
      search("stu") do
        menu.should eql ["student 2"]
      end
    end

    it "should show the term next to courses and sections" do
      search("course") do
        term_info = driver.find_element(:css, '.autocomplete_menu .name .context_info')
        term_info.text.should == "(#{@course.enrollment_term.name})"
      end

      search("section") do
        term_info = driver.find_element(:css, '.autocomplete_menu .name .context_info')
        term_info.text.should == "(#{@course.name} - #{@course.enrollment_term.name})"
      end

      # doesn't show term for sections when browsing
      browse_menu
      browse "the course", "Course Sections" do
        menu_items = driver.find_elements(:css, ".autocomplete_menu .name")
        menu_items.last.text.should == "the section"
      end
    end

    it "should allow searching under supported contexts" do
      browse_menu
      browse "the course" do
        search("t") { menu.should eql ["the group", "the other section", "the section", "student 1", "student 2"] }
        browse "Everyone" do
          # only returns users
          search("T") { menu.should eql ["student 1", "student 2"] }
        end
        browse "Course Sections" do
          # only returns sections
          search("student") { menu.should eql ["No results found"] }
          search("r") { menu.should eql ["the other section"] }
          browse "the section" do
            search("s") { menu.should eql ["student 1"] }
          end
        end
        browse "Student Groups" do
          # only returns groups
          search("student") { menu.should eql ["No results found"] }
          search("the") { menu.should eql ["the group"] }
          browse "the group" do
            search("s") { menu.should eql ["student 1"] }
            search("group") { menu.should eql ["No results found"] }
          end
        end
      end
    end

    it "should allow a user id in the url hash to add recipient" do
      skip_if_ie("Java crashes")
      # check without any user_name
      get "/conversations#/conversations?user_id=#{@s1.id}"
      wait_for_ajaximations
      tokens.should eql ["student 1"]
      # explanation of user_name param: we used to pass the user name in the
      # hash fragment, and it was spoofable. now we load that data via ajax.
      get "/conversations#/conversations?user_id=#{@s1.id}&user_name=some_fake_name"
      wait_for_ajaximations
      tokens.should eql ["student 1"]
    end

    it "should reject a non-contactable user id in the url hash" do
      skip_if_ie("Java crashes")
      other = User.create(:name => "other guy")
      get "/conversations#/conversations?user_id=#{other.id}"
      wait_for_ajaximations
      tokens.should eql []
    end

    it "should allow a non-contactable user in the hash if a shared conversation exists" do
      skip_if_ie("Java crashes")
      other = User.create(:name => "other guy")
      # if the users have a conversation in common already, then the recipient can be added
      c = Conversation.initiate([@user.id, other.id], true)
      get "/conversations#/conversations?user_id=#{other.id}&from_conversation_id=#{c.id}"
      wait_for_ajaximations
      tokens.should eql ["other guy"]
    end
  end

  context "media comments" do
    it "should add a media comment to the message form" do
      # don't have a good way to test kaltura here, so we just fake it up
      Kaltura::ClientV3.expects(:config).at_least(1).returns({})
      mo = MediaObject.new
      mo.media_id = '0_12345678'
      mo.media_type = 'audio'
      mo.context = @user
      mo.user = @user
      mo.title = "test title"
      mo.save!

      new_conversation

      message = submit_message_form(:media_comment => [mo.media_id, mo.media_type])
      message = "#message_#{message.id}"

      find_all_with_jquery("#{message} .message_attachments li").size.should == 1
      find_with_jquery("#{message} .message_attachments li a .title").text.should == mo.title
    end
  end

  context "attachments" do
    it "should be able to add an attachment to the message form" do
      new_conversation

      add_attachment_link = driver.find_element(:id, "action_add_attachment")
      add_attachment_link.should_not be_nil
      find_all_with_jquery("#attachment_list > .attachment:visible").should be_empty
      add_attachment_link.click
      keep_trying_until { find_all_with_jquery("#attachment_list > .attachment:visible").should be_present }
    end

    it "should be able to add multiple attachments to the message form" do
      new_conversation

      add_attachment_link = driver.find_element(:id, "action_add_attachment")
      add_attachment_link.click
      wait_for_animations
      add_attachment_link.click
      wait_for_animations
      add_attachment_link.click
      wait_for_animations
      find_all_with_jquery("#attachment_list > .attachment:visible").size.should == 3
    end

    it "should be able to remove attachments from the message form" do
      new_conversation

      add_attachment_link = driver.find_element(:id, "action_add_attachment")
      add_attachment_link.click
      wait_for_animations
      add_attachment_link.click
      wait_for_animations
      find_all_with_jquery("#attachment_list > .attachment:visible .remove_link")[1].click
      wait_for_animations
      find_all_with_jquery("#attachment_list > .attachment:visible").size.should == 1
    end

    it "should save attachments on initial messages on new conversations" do
      student_in_course
      filename, fullpath, data = get_file("testfile1.txt")

      new_conversation
      message = submit_message_form(:attachments => [fullpath])
      message = "#message_#{message.id}"

      find_all_with_jquery("#{message} .message_attachments li").size.should == 1
      find_with_jquery("#{message} .message_attachments li a .title").text.should == filename
      download_link = driver.find_element(:css, "#{message} .message_attachments li a")
      file = open(download_link.attribute('href'))
      file.read.should match data
    end

    it "should save attachments on new messages on existing conversations" do
      student_in_course
      filename, fullpath, data = get_file("testfile1.txt")

      new_conversation
      submit_message_form

      message = submit_message_form(:attachments => [fullpath])
      message = "#message_#{message.id}"

      find_all_with_jquery("#{message} .message_attachments li").size.should == 1
    end

    it "should save multiple attachments" do
      student_in_course
      file1 = get_file("testfile1.txt")
      file2 = get_file("testfile2.txt")

      new_conversation
      message = submit_message_form(:attachments => [file1[1], file2[1]])
      message = "#message_#{message.id}"

      find_all_with_jquery("#{message} .message_attachments li").size.should == 2
      find_with_jquery("#{message} .message_attachments li:first a .title").text.should == file1[0]
      find_with_jquery("#{message} .message_attachments li:last a .title").text.should == file2[0]
    end
  end

  def add_recipient(search)
    input = find_with_jquery("#create_message_form input:visible")
    input.send_keys(search)
    keep_trying_until { driver.execute_script("return $('#recipients').data('token_input').selector.last_search") == search }
    input.send_keys(:return)
  end

  context "user notes" do
    before (:each) do
      @the_teacher = User.create(:name => "teacher bob")
      @course.enroll_teacher(@the_teacher)
      @the_student = User.create(:name => "student bob")
      @course.enroll_student(@the_student)
    end

    it "should not allow user notes if not enabled" do
      @course.account.update_attribute :enable_user_notes, false
      new_conversation
      add_recipient("student bob")
      driver.find_element(:id, "add_to_faculty_journal").should_not be_displayed
    end

    it "should not allow user notes to teachers" do
      @course.account.update_attribute :enable_user_notes, true
      new_conversation
      add_recipient("teacher bob")
      driver.find_element(:id, "add_to_faculty_journal").should_not be_displayed
    end

    it "should not allow user notes on group conversations" do
      @course.account.update_attribute :enable_user_notes, true
      new_conversation
      add_recipient("student bob")
      add_recipient("teacher bob")
      driver.find_element(:id, "add_to_faculty_journal").should_not be_displayed
      find_with_jquery("#create_message_form input:visible").send_keys :backspace
      driver.find_element(:id, "add_to_faculty_journal").should be_displayed
    end

    it "should allow user notes on new private conversations with students" do
      @course.account.update_attribute :enable_user_notes, true
      new_conversation
      add_recipient("student bob")
      checkbox = driver.find_element(:id, "add_to_faculty_journal")
      checkbox.should be_displayed
      checkbox.click
      submit_message_form(:add_recipient => false)
      @the_student.user_notes.size.should eql(1)
    end

    it "should allow user notes on existing private conversations with students" do
      @course.account.update_attribute :enable_user_notes, true
      new_conversation
      add_recipient("student bob")
      submit_message_form(:add_recipient => false)
      checkbox = driver.find_element(:id, "add_to_faculty_journal")
      checkbox.should be_displayed
      checkbox.click
      submit_message_form
      @the_student.user_notes.size.should eql(1)
    end
  end

  context "submissions" do
    it "should list submission comments in the conversation" do
      @me = @user
      @bob = student_in_course(:name => "bob", :active_all => true).user
      submission1 = submission_model(:course => @course, :user => @bob)
      submission2 = submission_model(:course => @course, :user => @bob)
      submission1.add_comment(:comment => "hey bob", :author => @me)
      submission1.add_comment(:comment => "wut up teacher", :author => @bob)
      submission2.add_comment(:comment => "my name is bob", :author => @bob)
      submission2.assignment.grade_student(@bob, {:grade => 0.9})
      conversation(@bob)
      get "/conversations"
      elements = nil
      keep_trying_until {
        elements = find_all_with_jquery("#conversations > ul > li:visible")
        elements.size == 1
      }
      elements.first.click
      wait_for_ajaximations
      subs = driver.find_elements(:css, "div#messages .submission")
      subs.size.should == 2
      subs[0].find_element(:css, '.score').text.should == '0.9 / 1.5'
      subs[1].find_element(:css, '.score').text.should == 'no score'

      coms = subs[0].find_elements(:css, '.comment')
      coms.size.should == 1
      coms.first.find_element(:css, '.audience').text.should == 'bob'
      coms.first.find_element(:css, 'p').text.should == 'my name is bob'

      coms = subs[1].find_elements(:css, '.comment')
      coms.size.should == 2
      coms.first.find_element(:css, '.audience').text.should == 'bob'
      coms.first.find_element(:css, 'p').text.should == 'wut up teacher'
      coms.last.find_element(:css, '.audience').text.should == 'nobody@example.com'
      coms.last.find_element(:css, 'p').text.should == 'hey bob'
    end

    it "should interleave submissions with messages based on comment time" do
      SubmissionComment.any_instance.stubs(:current_time_from_proper_timezone).returns(10.minutes.ago, 8.minutes.ago)
      @me = @user
      @bob = student_in_course(:name => "bob", :active_all => true).user
      @conversation = conversation(@bob).conversation
      @conversation.conversation_messages.first.update_attribute(:created_at, 9.minutes.ago)
      submission1 = submission_model(:course => @course, :user => @bob)
      submission1.add_comment(:comment => "hey bob", :author => @me)

      # message comes first, then submission, due to creation times
      msgs = get_messages
      msgs.size.should == 2
      msgs[0].should have_class('message')
      msgs[1].should have_class('submission')

      # now new submission comment bumps it up
      submission1.add_comment(:comment => "hey teach", :author => @bob)
      msgs = get_messages
      msgs.size.should == 2
      msgs[0].should have_class('submission')
      msgs[1].should have_class('message')

      # new message appears on top, submission now in the middle
      @conversation.add_message(@bob, 'ohai there').update_attribute(:created_at, 7.minutes.ago)
      msgs = get_messages
      msgs.size.should == 3
      msgs[0].should have_class('message')
      msgs[1].should have_class('submission')
      msgs[2].should have_class('message')
    end

    it "should allow deleting submission messages from the conversation" do
      @me = @user
      @bob = student_in_course(:name => "bob", :active_all => true).user
      submission1 = submission_model(:course => @course, :user => @bob)
      submission1.add_comment(:comment => "hey teach", :author => @bob)
      @conversation = @me.conversations.first
      @conversation.should be_present

      msgs = get_messages
      msgs.size.should == 1
      msgs.first.click

      delete_selected_messages

      @conversation.reload
      @conversation.last_message_at.should be_nil
    end
  end

  context "group conversations" do
    before (:each) do
      @course.update_attribute(:name, "the course")
      @course.default_section.update_attribute(:name, "the section")
      @other_section = @course.course_sections.create(:name => "the other section")

      s1 = User.create(:name => "student 1")
      @course.enroll_user(s1)
      s2 = User.create(:name => "student 2")
      @course.enroll_user(s2, "StudentEnrollment", :section => @other_section)

      @group = @course.groups.create(:name => "the group")
      @group.users << s1

      new_conversation
      @input = find_with_jquery("#create_message_form input:visible")
      @checkbox = driver.find_element(:id, "group_conversation")
    end

    def choose_recipient(*names)
      name = names.shift
      level = 1

      @input.send_keys(name)
      wait_for_ajaximations(150)
      loop do
        keep_trying_until { find_all_with_jquery('.autocomplete_menu:visible .list').size == level }
        driver.execute_script("return $('.autocomplete_menu:visible .list').last().find('ul').last().find('li').toArray();").detect { |e|
          (e.find_element(:tag_name, :b).text rescue e.text) == name
        }.click
        wait_for_ajaximations

        break if names.empty?

        level += 1
        name = names.shift
      end
      keep_trying_until { find_with_jquery('.autocomplete_menu:visible').nil? }
    end

    it "should not be an option with no recipients" do
      @checkbox.should_not be_displayed
    end

    it "should not be an option for a single individual recipient" do
      choose_recipient("student 1")
      @checkbox.should_not be_displayed
    end

    it "should be an option, default false, for a single 'bulk' recipient" do
      choose_recipient("the course", "Everyone", "Select All")
      @checkbox.should be_displayed
      is_checked("#group_conversation").should be_false
    end

    it "should be an option, default false, for multiple individual recipients" do
      choose_recipient("student 1")
      choose_recipient("student 2")
      @checkbox.should be_displayed
      is_checked("#group_conversation").should be_false
    end

    it "should disappear when there are no longer multiple recipients" do
      choose_recipient("student 1")
      choose_recipient("student 2")
      @input.send_keys([:backspace])
      @checkbox.should_not be_displayed
    end

    it "should revert to false after disappearing and reappearing" do
      choose_recipient("student 1")
      choose_recipient("student 2")
      @checkbox.click
      @input.send_keys([:backspace])
      choose_recipient("student 2")
      @checkbox.should be_displayed
      is_checked("#group_conversation").should be_false
    end
  end

  context "form audience" do
    before (:each) do
      # have @course, @teacher from before
      # creates @student
      student_in_course(:course => @course, :active_all => true)

      @course.update_attribute(:name, "the course")

      @group = @course.groups.create(:name => "the group")
      @group.participating_users << @student

      conversation(@teacher, @student)
    end

    it "should link to the course page" do
      get_messages

      find_with_jquery("#create_message_form .audience a").click
      driver.current_url.should match %r{/courses/#{@course.id}}
    end

    it "should not be a link in the left conversation list panel" do
      new_conversation

      find_all_with_jquery("#conversations .audience a").should be_empty
    end
  end

  context "private messages" do
    before do
      @course.update_attribute(:name, "the course")
      @course1 = @course
      @s1 = User.create(:name => "student1")
      @s2 = User.create(:name => "student2")
      @course1.enroll_user(@s1)
      @course1.enroll_user(@s2)

      ConversationMessage.any_instance.stubs(:current_time_from_proper_timezone).returns(*100.times.to_a.reverse.map{ |h| Time.now.utc - h.hours })

      @c1 = conversation(@user, @s1)
      @c1.add_message('yay i sent this')
    end

    it "should select the new conversation" do
      new_conversation
      add_recipient("student2")

      submit_message_form(:message => "ohai", :add_recipient => false).should_not be_nil
    end

    it "should select the existing conversation" do
      new_conversation
      add_recipient("student1")

      submit_message_form(:message => "ohai", :add_recipient => false).should_not be_nil
    end
  end

  context "batch messages" do
    it "shouldn't show anything in conversation list when sending batch messages to new recipients" do
      @course.default_section.update_attribute(:name, "the section")

      @s1 = User.create(:name => "student1")
      @s2 = User.create(:name => "student2")
      @course.enroll_user(@s1)
      @course.enroll_user(@s2)

      get "/conversations"

      add_recipient("student1")
      add_recipient("student2")
      driver.find_element(:id, "body").send_keys "testing testing"
      driver.find_element(:css, '#create_message_form button[type="submit"]').click

      wait_for_ajaximations

      assert_flash_notice_message /Messages Sent/

      # no conversations should show up in the conversation list
      conversations = driver.find_elements(:css, "#conversations > ul > li")
      conversations.size.should == 1
      conversations.first["id"].should == "conversations_loader"
    end
  end

  context "sent filter" do
    before do
      @course.update_attribute(:name, "the course")
      @course1 = @course
      @s1 = User.create(:name => "student1")
      @s2 = User.create(:name => "student2")
      @course1.enroll_user(@s1)
      @course1.enroll_user(@s2)

      ConversationMessage.any_instance.stubs(:current_time_from_proper_timezone).returns(*100.times.to_a.reverse.map{ |h| Time.now.utc - h.hours })

      @c1 = conversation(@user, @s1)
      @c2 = conversation(@user, @s2)
      @c1.add_message('yay i sent this')
      @c2.conversation.add_message(@s2, "ohai im not u so this wont show up on the left")

      get "/conversations/sent"

      conversations = find_all_with_jquery("#conversations > ul > li:visible")
      conversations.first.attribute('id').should eql("conversation_#{@c1.conversation_id}")
      conversations.first.text.should match(/yay i sent this/)
      conversations.last.attribute('id').should eql("conversation_#{@c2.conversation_id}")
      conversations.last.text.should match(/test/)
    end

    it "should reorder based on last authored message" do
      driver.find_element(:id, "conversation_#{@c2.conversation_id}").click
      wait_for_ajaximations

      submit_message_form(:message => "qwerty")

      conversations = find_all_with_jquery("#conversations > ul > li:visible")
      conversations.size.should eql 2
      conversations.first.text.should match(/qwerty/)
      conversations.last.text.should match(/yay i sent this/)
    end

    it "should remove the conversation when the last message by the author is deleted" do
      driver.find_element(:id, "conversation_#{@c2.conversation_id}").click
      wait_for_ajaximations

      msgs = driver.find_elements(:css, "div#messages ul.messages > li")
      msgs.size.should == 2
      msgs.last.click

      delete_selected_messages
    end

    it "should show/update all conversations when sending a bulk private message" do
      @s3 = User.create(:name => "student3")
      @course1.enroll_user(@s3)

      new_conversation(false)
      add_recipient("student1")
      add_recipient("student2")
      add_recipient("student3")

      submit_message_form(:message => "ohai guys", :add_recipient => false, :group_conversation => false)

      conversations = find_all_with_jquery("#conversations > ul > li:visible")
      conversations.size.should eql 3
      conversations.each do |conversation|
        conversation.text.should match(/ohai guys/)
      end
    end
  end

  context "context filtering" do
    before do
      @course.update_attribute(:name, "the course")
      @course1 = @course
      @s1 = User.create(:name => "student1")
      @s2 = User.create(:name => "student2")
      @course1.enroll_user(@s1)
      @course1.enroll_user(@s2)
      @group = @course1.groups.create(:name => "the group")
      @group.users << @user << @s1 << @s2

      @course2 = course(:active_all => true, :course_name => "that course")
      @course2.enroll_teacher(@user).accept
      @course2.enroll_user(@s1)
    end

    it "should capture the course when sending a message to a group" do
      new_conversation
      browse_menu

      browse("the course", "Student Groups", "the group"){ click "Select All" }
      submit_message_form(:add_recipient => false)

      audience = find_with_jquery("#create_message_form ul.conversations .audience")
      audience.text.should include @course1.name
      audience.text.should_not include @course2.name
      audience.text.should include @group.name
    end

    it "should capture the course when sending a message to a user under a course" do
      new_conversation
      browse_menu

      browse("the course"){ search("stu"){ click "student1" } }
      submit_message_form(:add_recipient => false)

      audience = find_with_jquery("#create_message_form ul.conversations .audience")
      audience.text.should include @course1.name
      audience.text.should_not include @course2.name
      audience.text.should_not include @group.name
    end

    it "should let you filter by a course" do
      new_conversation
      browse_menu
      browse("the course", "Everyone"){ click "Select All" }
      submit_message_form(:add_recipient => false, :message => "asdf")

      new_conversation(false)
      browse_menu
      browse("that course", "Everyone"){ click "Select All" }
      submit_message_form(:add_recipient => false, :message => "qwerty")

      find_all_with_jquery('#conversations > ul > li:visible').size.should eql 2

      @input = find_with_jquery("#context_tags_filter input:visible")
      search("the course", "context_tags"){ click("the course") }

      keep_trying_until { driver.find_element(:id, "create_message_form") }
      conversations = find_all_with_jquery('#conversations > ul > li:visible')
      conversations.size.should eql 1
      conversations.first.find_element(:css, 'p').text.should eql 'asdf'
    end

    it "should show the term name by the course" do
      new_conversation
      browse_menu

      browse("the course"){ search("stu"){ click "student1" } }
      submit_message_form(:add_recipient => false)

      @input = find_with_jquery("#context_tags_filter input:visible")
      search("the course", "context_tags") do
        term_info = driver.find_element(:css, '.autocomplete_menu .name .context_info')
        term_info.text.should == "(#{@course1.enrollment_term.name})"
      end
    end

    it "should not show the default term name" do
      new_conversation
      browse_menu

      browse("the course"){ search("stu"){ click "student1" } }
      submit_message_form(:add_recipient => false)

      @input = find_with_jquery("#context_tags_filter input:visible")
      search("that course", "context_tags") do
        term_info = driver.find_element(:css, '.autocomplete_menu .name')
        term_info.text.should == "that course"
      end
    end
  end
end
