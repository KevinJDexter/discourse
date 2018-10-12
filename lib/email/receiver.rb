require "digest"
require_dependency "new_post_manager"
require_dependency "post_action_creator"
require_dependency "html_to_markdown"
require_dependency "plain_text_to_markdown"
require_dependency "upload_creator"

module Email

  class Receiver
    include ActionView::Helpers::NumberHelper

    # If you add a new error, you need to
    #   * add it to Email::Processor#handle_failure()
    #   * add text to server.en.yml (parent key: "emails.incoming.errors")
    class ProcessingError              < StandardError; end
    class EmptyEmailError              < ProcessingError; end
    class ScreenedEmailError           < ProcessingError; end
    class UserNotFoundError            < ProcessingError; end
    class AutoGeneratedEmailError      < ProcessingError; end
    class BouncedEmailError            < ProcessingError; end
    class NoBodyDetectedError          < ProcessingError; end
    class NoSenderDetectedError        < ProcessingError; end
    class FromReplyByAddressError      < ProcessingError; end
    class InactiveUserError            < ProcessingError; end
    class SilencedUserError            < ProcessingError; end
    class BadDestinationAddress        < ProcessingError; end
    class StrangersNotAllowedError     < ProcessingError; end
    class InsufficientTrustLevelError  < ProcessingError; end
    class ReplyUserNotMatchingError    < ProcessingError; end
    class TopicNotFoundError           < ProcessingError; end
    class TopicClosedError             < ProcessingError; end
    class InvalidPost                  < ProcessingError; end
    class TooShortPost                 < ProcessingError; end
    class InvalidPostAction            < ProcessingError; end
    class UnsubscribeNotAllowed        < ProcessingError; end
    class EmailNotAllowed              < ProcessingError; end
    class OldDestinationError          < ProcessingError; end

    attr_reader :incoming_email
    attr_reader :raw_email
    attr_reader :mail
    attr_reader :message_id

    COMMON_ENCODINGS ||= [-"utf-8", -"windows-1252", -"iso-8859-1"]

    def self.formats
      @formats ||= Enum.new(plaintext: 1, markdown: 2)
    end

    def initialize(mail_string, opts = {})
      raise EmptyEmailError if mail_string.blank?
      @staged_users = []
      @raw_email = mail_string

      COMMON_ENCODINGS.each do |encoding|
        fixed = try_to_encode(mail_string, encoding)
        break @raw_email = fixed if fixed.present?
      end

      @mail = Mail.new(@raw_email)
      @message_id = @mail.message_id.presence || Digest::MD5.hexdigest(mail_string)
      @opts = opts
    end

    def process!
      return if is_blacklisted?
      DistributedMutex.synchronize(@message_id) do
        begin
          return if IncomingEmail.exists?(message_id: @message_id)
          ensure_valid_address_lists
          @from_email, @from_display_name = parse_from_field(@mail)
          @incoming_email = create_incoming_email
          process_internal
        rescue => e
          error = e.to_s
          error = e.class.name if error.blank?
          @incoming_email.update_columns(error: error) if @incoming_email
          delete_staged_users
          raise
        end
      end
    end

    def ensure_valid_address_lists
      [:to, :cc, :bcc].each do |field|
        addresses = @mail[field]

        if addresses&.errors.present?
          @mail[field] = addresses.to_s.scan(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)
        end
      end
    end

    def is_blacklisted?
      return false if SiteSetting.ignore_by_title.blank?
      Regexp.new(SiteSetting.ignore_by_title, Regexp::IGNORECASE) =~ @mail.subject
    end

    def create_incoming_email
      IncomingEmail.create(
        message_id: @message_id,
        raw: @raw_email,
        subject: subject,
        from_address: @from_email,
        to_addresses: @mail.to&.map(&:downcase)&.join(";"),
        cc_addresses: @mail.cc&.map(&:downcase)&.join(";"),
      )
    end

    def process_internal
      raise BouncedEmailError  if is_bounce?
      raise NoSenderDetectedError if @from_email.blank?
      raise FromReplyByAddressError if is_from_reply_by_email_address?
      raise ScreenedEmailError if ScreenedEmail.should_block?(@from_email)

      hidden_reason_id = is_spam? ? Post.hidden_reasons[:email_spam_header_found] : nil

      user = find_user(@from_email)

      if user.present?
        log_and_validate_user(user)
      else
        raise UserNotFoundError unless SiteSetting.enable_staged_users
      end

      body, elided = select_body
      body ||= ""

      raise NoBodyDetectedError if body.blank? && attachments.empty?

      if is_auto_generated? && !sent_to_mailinglist_mirror?
        @incoming_email.update_columns(is_auto_generated: true)

        if SiteSetting.block_auto_generated_emails?
          raise AutoGeneratedEmailError
        end
      end

      if action = subscription_action_for(body, subject)
        raise UnsubscribeNotAllowed if user.nil?
        send_subscription_mail(action, user)
        return
      end

      # Lets create a staged user if there isn't one yet. We will try to
      # delete staged users in process!() if something bad happens.
      if user.nil?
        user = find_or_create_user!(@from_email, @from_display_name)
        log_and_validate_user(user)
      end

      if post = find_related_post
        create_reply(user: user,
                     raw: body,
                     elided: elided,
                     hidden_reason_id: hidden_reason_id,
                     post: post,
                     topic: post.topic,
                     skip_validations: user.staged?)
      else
        first_exception = nil

        destinations.each do |destination|
          begin
            process_destination(destination, user, body, elided, hidden_reason_id)
          rescue => e
            first_exception ||= e
          else
            return
          end
        end

        raise first_exception if first_exception

        post = find_related_post(force: true)

        if post && Guardian.new(user).can_see_post?(post)
          num_of_days = SiteSetting.disallow_reply_by_email_after_days

          if num_of_days > 0 && post.created_at < num_of_days.days.ago
            raise OldDestinationError.new("#{Discourse.base_url}/p/#{post.id}")
          end
        end

        raise BadDestinationAddress
      end
    end

    def log_and_validate_user(user)
      @incoming_email.update_columns(user_id: user.id)

      raise InactiveUserError if !user.active && !user.staged
      raise SilencedUserError if user.silenced?
    end

    def is_bounce?
      return false unless @mail.bounced? || verp

      @incoming_email.update_columns(is_bounce: true)

      if verp && (bounce_key = verp[/\+verp-(\h{32})@/, 1]) && (email_log = EmailLog.find_by(bounce_key: bounce_key))
        email_log.update_columns(bounced: true)
        email = email_log.user.try(:email).presence
      end

      email ||= @from_email

      if @mail.error_status.present? && Array.wrap(@mail.error_status).any? { |s| s.start_with?("4.") }
        Email::Receiver.update_bounce_score(email, SiteSetting.soft_bounce_score)
      else
        Email::Receiver.update_bounce_score(email, SiteSetting.hard_bounce_score)
      end

      true
    end

    def is_from_reply_by_email_address?
      Email::Receiver.reply_by_email_address_regex.match(@from_email)
    end

    def verp
      @verp ||= all_destinations.select { |to| to[/\+verp-\h{32}@/] }.first
    end

    def self.update_bounce_score(email, score)
      if user = User.find_by_email(email)
        old_bounce_score = user.user_stat.bounce_score
        new_bounce_score = old_bounce_score + score
        range = (old_bounce_score + 1..new_bounce_score)

        user.user_stat.bounce_score = new_bounce_score
        user.user_stat.reset_bounce_score_after = SiteSetting.reset_bounce_score_after_days.days.from_now
        user.user_stat.save!

        if user.active && range === SiteSetting.bounce_score_threshold_deactivate
          user.update!(active: false)
          reason = I18n.t("user.deactivated", email: user.email)
          StaffActionLogger.new(Discourse.system_user).log_user_deactivate(user, reason)
        elsif range === SiteSetting.bounce_score_threshold
          # NOTE: we check bounce_score before sending emails
          # So log we revoked the email...
          reason = I18n.t("user.email.revoked", email: user.email, date: user.user_stat.reset_bounce_score_after)
          StaffActionLogger.new(Discourse.system_user).log_revoke_email(user, reason)
          # ... and PM the user
          SystemMessage.create_from_system_user(user, :email_revoked)
        end
      end
    end

    def is_auto_generated?
      return false if SiteSetting.auto_generated_whitelist.split('|').include?(@from_email)
      @mail[:precedence].to_s[/list|junk|bulk|auto_reply/i] ||
      @mail[:from].to_s[/(mailer[\-_]?daemon|post[\-_]?master|no[\-_]?reply)@/i] ||
      @mail[:subject].to_s[/^\s*(Auto:|Automatic reply|Autosvar|Automatisk svar|Automatisch antwoord|Abwesenheitsnotiz|Risposta Non al computer|Automatisch antwoord|Auto Response|Respuesta automática|Fuori sede|Out of Office|Frånvaro|Réponse automatique)/i] ||
      @mail.header.to_s[/auto[\-_]?(response|submitted|replied|reply|generated|respond)|holidayreply|machinegenerated/i]
    end

    def is_spam?
      case SiteSetting.email_in_spam_header
      when 'X-Spam-Flag'
        @mail[:x_spam_flag].to_s[/YES/i]
      when 'X-Spam-Status'
        @mail[:x_spam_status].to_s[/^Yes, /i]
      else
        false
      end
    end

    def select_body
      text = nil
      html = nil
      text_content_type = nil

      if @mail.multipart?
        text = fix_charset(@mail.text_part)
        html = fix_charset(@mail.html_part)
        text_content_type = @mail.text_part&.content_type
      elsif @mail.content_type.to_s["text/html"]
        html = fix_charset(@mail)
      elsif @mail.content_type.blank? || @mail.content_type["text/plain"]
        text = fix_charset(@mail)
        text_content_type = @mail.content_type
      end

      return unless text.present? || html.present?

      if text.present?
        text = trim_discourse_markers(text)
        text, elided_text = trim_reply_and_extract_elided(text)

        if @opts[:convert_plaintext] || sent_to_mailinglist_mirror?
          text_content_type ||= ""
          converter_opts = {
            format_flowed: !!(text_content_type =~ /format\s*=\s*["']?flowed["']?/i),
            delete_flowed_space: !!(text_content_type =~ /DelSp\s*=\s*["']?yes["']?/i)
          }
          text = PlainTextToMarkdown.new(text, converter_opts).to_markdown
          elided_text = PlainTextToMarkdown.new(elided_text, converter_opts).to_markdown
        end
      end

      markdown, elided_markdown = if html.present?
        # use the first html extracter that matches
        if html_extracter = HTML_EXTRACTERS.select { |_, r| html[r] }.min_by { |_, r| html =~ r }
          doc = Nokogiri::HTML.fragment(html)
          self.send(:"extract_from_#{html_extracter[0]}", doc)
        else
          markdown = HtmlToMarkdown.new(html, keep_img_tags: true, keep_cid_imgs: true).to_markdown
          markdown = trim_discourse_markers(markdown)
          trim_reply_and_extract_elided(markdown)
        end
      end

      if text.blank? || (SiteSetting.incoming_email_prefer_html && markdown.present?)
        return [markdown, elided_markdown, Receiver::formats[:markdown]]
      else
        return [text, elided_text, Receiver::formats[:plaintext]]
      end
    end

    def to_markdown(html, elided_html)
      markdown = HtmlToMarkdown.new(html, keep_img_tags: true, keep_cid_imgs: true).to_markdown
      [EmailReplyTrimmer.trim(markdown), HtmlToMarkdown.new(elided_html).to_markdown]
    end

    HTML_EXTRACTERS ||= [
      [:gmail, /class="gmail_(signature|extra)/],
      [:outlook, /id="(divRplyFwdMsg|Signature)"/],
      [:word, /class="WordSection1"/],
      [:exchange, /name="message(Body|Reply)Section"/],
      [:apple_mail, /id="AppleMailSignature"/],
      [:mozilla, /class="moz-/],
      [:protonmail, /class="protonmail_/],
      [:zimbra, /data-marker="__/],
      [:newton, /(id|class)="cm_/],
    ]

    def extract_from_gmail(doc)
      # GMail adds a bunch of 'gmail_' prefixed classes like: gmail_signature, gmail_extra, gmail_quote, gmail_default...
      elided = doc.css(".gmail_signature, .gmail_extra").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def extract_from_outlook(doc)
      # Outlook properly identifies the signature and any replied/forwarded email
      # Use their id to remove them and anything that comes after
      elided = doc.css("#Signature, #Signature ~ *, hr, #divRplyFwdMsg, #divRplyFwdMsg ~ *").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def extract_from_word(doc)
      # Word (?) keeps the content in the 'WordSection1' class and uses <p> tags
      # When there's something else (<table>, <div>, etc..) there's high chance it's a signature or forwarded email
      elided = doc.css(".WordSection1 > :not(p):not(ul):first-of-type, .WordSection1 > :not(p):not(ul):first-of-type ~ *").remove
      to_markdown(doc.at(".WordSection1").to_html, elided.to_html)
    end

    def extract_from_exchange(doc)
      # Exchange is using the 'messageReplySection' class for forwarded emails
      # And 'messageBodySection' for the actual email
      elided = doc.css("div[name='messageReplySection']").remove
      to_markdown(doc.css("div[name='messageReplySection']").to_html, elided.to_html)
    end

    def extract_from_apple_mail(doc)
      # AppleMail is the worst. It adds 'AppleMailSignature' ids (!) to several div/p with no deterministic rules
      # Our best guess is to elide whatever comes after that.
      elided = doc.css("#AppleMailSignature:last-of-type ~ *").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def extract_from_mozilla(doc)
      # Mozilla (Thunderbird ?) properly identifies signature and forwarded emails
      # Remove them and anything that comes after
      elided = doc.css("*[class^='moz-'], *[class^='moz-'] ~ *").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def extract_from_protonmail(doc)
      # Removes anything that has a class starting with "protonmail_" and everything after that
      elided = doc.css("*[class^='protonmail_'], *[class^='protonmail_'] ~ *").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def extract_from_zimbra(doc)
      # Removes anything that has a 'data-marker' attribute
      elided = doc.css("*[data-marker]").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def extract_from_newton(doc)
      # Removes anything that has an id or a class starting with 'cm_'
      elided = doc.css("*[id^='cm_'], *[class^='cm_']").remove
      to_markdown(doc.to_html, elided.to_html)
    end

    def trim_reply_and_extract_elided(text)
      return [text, ""] if @opts[:skip_trimming]
      EmailReplyTrimmer.trim(text, true)
    end

    def fix_charset(mail_part)
      return nil if mail_part.blank? || mail_part.body.blank?

      string = mail_part.body.decoded rescue nil

      return nil if string.blank?

      # common encodings
      encodings = COMMON_ENCODINGS.dup
      encodings.unshift(mail_part.charset) if mail_part.charset.present?

      # mail (>=2.5) decodes mails with 8bit transfer encoding to utf-8, so
      # always try UTF-8 first
      if mail_part.content_transfer_encoding == "8bit"
        encodings.delete("UTF-8")
        encodings.unshift("UTF-8")
      end

      encodings.uniq.each do |encoding|
        fixed = try_to_encode(string, encoding)
        return fixed if fixed.present?
      end

      nil
    end

    def try_to_encode(string, encoding)
      encoded = string.encode("UTF-8", encoding)
      !encoded.nil? && encoded.valid_encoding? ? encoded : nil
    rescue Encoding::InvalidByteSequenceError,
           Encoding::UndefinedConversionError,
           Encoding::ConverterNotFoundError
      nil
    end

    def previous_replies_regex
      @previous_replies_regex ||= /^--[- ]\n\*#{I18n.t("user_notifications.previous_discussion")}\*\n/im
    end

    def trim_discourse_markers(reply)
      reply.split(previous_replies_regex)[0]
    end

    def parse_from_field(mail)
      return unless mail[:from]

      if mail[:from].errors.blank?
        mail[:from].address_list.addresses.each do |address_field|
          address_field.decoded
          from_address = address_field.address
          from_display_name = address_field.display_name.try(:to_s)
          return [from_address&.downcase, from_display_name&.strip] if from_address["@"]
        end
      end

      return extract_from_address_and_name(mail.from) if mail.from.is_a? String

      if mail.from.is_a? Mail::AddressContainer
        mail.from.each do |from|
          from_address, from_display_name = extract_from_address_and_name(from)
          return [from_address, from_display_name] if from_address
        end
      end

      nil
    rescue StandardError
      nil
    end

    def extract_from_address_and_name(value)
      if value[/<[^>]+>/]
        from_address = value[/<([^>]+)>/, 1]
        from_display_name = value[/^([^<]+)/, 1]
      end

      if (from_address.blank? || !from_address["@"]) && value[/\[mailto:[^\]]+\]/]
        from_address = value[/\[mailto:([^\]]+)\]/, 1]
        from_display_name = value[/^([^\[]+)/, 1]
      end

      [from_address&.downcase, from_display_name&.strip]
    end

    def subject
      @subject ||=
        if mail_subject = @mail.subject
          mail_subject.delete("\u0000")
        else
          I18n.t("emails.incoming.default_subject", email: @from_email)
        end
    end

    def find_user(email)
      User.find_by_email(email)
    end

    def find_or_create_user(email, display_name, raise_on_failed_create: false)
      user = nil

      User.transaction do
        user = User.find_by_email(email)

        if user.nil? && SiteSetting.enable_staged_users
          raise EmailNotAllowed unless EmailValidator.allowed?(email)

          username = UserNameSuggester.sanitize_username(display_name) if display_name.present?
          begin
            user = User.create!(
              email: email,
              username: UserNameSuggester.suggest(username.presence || email),
              name: display_name.presence || User.suggest_name(email),
              staged: true
            )
            @staged_users << user
          rescue PG::UniqueViolation, ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
            raise if raise_on_failed_create
            user = nil
          end
        end
      end

      user
    end

    def find_or_create_user!(email, display_name)
      find_or_create_user(email, display_name, raise_on_failed_create: true)
    end

    def all_destinations
      @all_destinations ||= [
        @mail.destinations,
        [@mail[:x_forwarded_to]].flatten.compact.map(&:decoded),
        [@mail[:delivered_to]].flatten.compact.map(&:decoded),
      ].flatten.select(&:present?).uniq.lazy
    end

    def destinations
      @destinations ||= all_destinations
        .map { |d| Email::Receiver.check_address(d) }
        .reject(&:blank?)
    end

    def sent_to_mailinglist_mirror?
      @sent_to_mailinglist_mirror ||= begin
        destinations.each do |destination|
          next unless destination[:type] == :category

          category = destination[:obj]
          return true if category.mailinglist_mirror?
        end

        false
      end
    end

    def self.check_address(address)
      # only check for a group/category when 'email_in' is enabled
      if SiteSetting.email_in
        group = Group.find_by_email(address)
        return { type: :group, obj: group } if group

        category = Category.find_by_email(address)
        return { type: :category, obj: category } if category
      end

      # reply
      match = Email::Receiver.reply_by_email_address_regex.match(address)
      if match && match.captures
        match.captures.each do |c|
          next if c.blank?
          post_reply_key = PostReplyKey.find_by(reply_key: c)
          return { type: :reply, obj: post_reply_key } if post_reply_key
        end
      end
      nil
    end

    def process_destination(destination, user, body, elided, hidden_reason_id)
      return if SiteSetting.enable_forwarded_emails &&
                has_been_forwarded? &&
                process_forwarded_email(destination, user)

      case destination[:type]
      when :group
        group = destination[:obj]
        create_group_post(group, user, body, elided, hidden_reason_id)

      when :category
        category = destination[:obj]

        raise StrangersNotAllowedError    if user.staged? && !category.email_in_allow_strangers
        raise InsufficientTrustLevelError if !user.has_trust_level?(SiteSetting.email_in_min_trust) && !sent_to_mailinglist_mirror?

        create_topic(user: user,
                     raw: body,
                     elided: elided,
                     hidden_reason_id: hidden_reason_id,
                     title: subject,
                     category: category.id,
                     skip_validations: user.staged?)

      when :reply
        post_reply_key = destination[:obj]

        if post_reply_key.user_id != user.id && !forwarded_reply_key?(post_reply_key, user)
          raise ReplyUserNotMatchingError, "post_reply_key.user_id => #{post_reply_key.user_id.inspect}, user.id => #{user.id.inspect}"
        end

        post = Post.with_deleted.find(post_reply_key.post_id)

        create_reply(user: user,
                     raw: body,
                     elided: elided,
                     hidden_reason_id: hidden_reason_id,
                     post: post,
                     topic: post&.topic,
                     skip_validations: user.staged?)
      end
    end

    def create_group_post(group, user, body, elided, hidden_reason_id)
      # ensure user PM emails are enabled (since user is posting via email)
      if !user.staged && !user.user_option.email_private_messages
        user.user_option.update!(email_private_messages: true)
      end

      message_ids = Email::Receiver.extract_reply_message_ids(@mail, max_message_id_count: 5)
      post_ids = []

      incoming_emails = IncomingEmail
        .where(message_id: message_ids)
        .addressed_to_user(user)
        .pluck(:post_id, :to_addresses, :cc_addresses)

      incoming_emails.each do |post_id, to_addresses, cc_addresses|
        post_ids << post_id if contains_email_address_of_user?(to_addresses, user) ||
          contains_email_address_of_user?(cc_addresses, user)
      end

      if post_ids.any? && post = Post.where(id: post_ids).order(:created_at).last
        create_reply(user: user,
                     raw: body,
                     elided: elided,
                     hidden_reason_id: hidden_reason_id,
                     post: post,
                     topic: post.topic,
                     skip_validations: true)
      else
        create_topic(user: user,
                     raw: body,
                     elided: elided,
                     hidden_reason_id: hidden_reason_id,
                     title: subject,
                     archetype: Archetype.private_message,
                     target_group_names: [group.name],
                     is_group_message: true,
                     skip_validations: true)
      end
    end

    def forwarded_reply_key?(post_reply_key, user)
      incoming_emails = IncomingEmail
        .joins(:post)
        .where('posts.topic_id = ?', post_reply_key.post.topic_id)
        .addressed_to(post_reply_key.reply_key)
        .addressed_to_user(user)
        .pluck(:to_addresses, :cc_addresses)

      incoming_emails.each do |to_addresses, cc_addresses|
        next unless contains_email_address_of_user?(to_addresses, user) ||
          contains_email_address_of_user?(cc_addresses, user)

        return true if contains_reply_by_email_address(to_addresses, post_reply_key.reply_key) ||
          contains_reply_by_email_address(cc_addresses, post_reply_key.reply_key)
      end

      false
    end

    def contains_email_address_of_user?(addresses, user)
      return false if addresses.blank?

      addresses = addresses.split(";")
      user.user_emails.any? { |user_email| addresses.include?(user_email.email) }
    end

    def contains_reply_by_email_address(addresses, reply_key)
      return false if addresses.blank?

      addresses.split(";").each do |address|
        match = Email::Receiver.reply_by_email_address_regex.match(address)
        return true if match && match.captures&.include?(reply_key)
      end

      false
    end

    def has_been_forwarded?
      subject[/^[[:blank:]]*(fwd?|tr)[[:blank:]]?:/i] && embedded_email_raw.present?
    end

    def embedded_email_raw
      return @embedded_email_raw if @embedded_email_raw
      text = fix_charset(@mail.multipart? ? @mail.text_part : @mail)
      @embedded_email_raw, @before_embedded = EmailReplyTrimmer.extract_embedded_email(text)
      @embedded_email_raw
    end

    def process_forwarded_email(destination, user)
      embedded = Mail.new(embedded_email_raw)
      email, display_name = parse_from_field(embedded)

      return false if email.blank? || !email["@"]

      embedded_user = find_or_create_user(email, display_name)
      raw = try_to_encode(embedded.decoded, "UTF-8").presence || embedded.to_s
      title = embedded.subject.presence || subject

      case destination[:type]
      when :group
        group = destination[:obj]
        post = create_topic(user: embedded_user,
                            raw: raw,
                            title: title,
                            archetype: Archetype.private_message,
                            target_usernames: [user.username],
                            target_group_names: [group.name],
                            is_group_message: true,
                            skip_validations: true,
                            created_at: embedded.date)

      when :category
        category = destination[:obj]

        return false if user.staged? && !category.email_in_allow_strangers
        return false if !user.has_trust_level?(SiteSetting.email_in_min_trust)

        post = create_topic(user: embedded_user,
                            raw: raw,
                            title: title,
                            category: category.id,
                            skip_validations: embedded_user.staged?,
                            created_at: embedded.date)
      else
        return false
      end

      if post&.topic
        # mark post as seen for the forwarder
        PostTiming.record_timing(user_id: user.id, topic_id: post.topic_id, post_number: post.post_number, msecs: 5000)

        # create reply when available
        if @before_embedded.present?
          post_type = Post.types[:regular]
          post_type = Post.types[:whisper] if post.topic.private_message? && group.usernames[user.username]

          create_reply(user: user,
                       raw: @before_embedded,
                       post: post,
                       topic: post.topic,
                       post_type: post_type,
                       skip_validations: user.staged?)
        end
      end

      true
    end

    def self.reply_by_email_address_regex(extract_reply_key = true)
      reply_addresses = [SiteSetting.reply_by_email_address]
      reply_addresses << (SiteSetting.alternative_reply_by_email_addresses.presence || "").split("|")

      reply_addresses.flatten!
      reply_addresses.select!(&:present?)
      reply_addresses.map! { |a| Regexp.escape(a) }
      reply_addresses.map! { |a| a.gsub("\+", "\+?") }
      reply_addresses.map! { |a| a.gsub(Regexp.escape("%{reply_key}"), "(\\h{32})?") }
      if reply_addresses.empty?
        /$a/ # a regex that can never match
      else
        /#{reply_addresses.join("|")}/
      end
    end

    def group_incoming_emails_regex
      @group_incoming_emails_regex ||= Regexp.union Group.pluck(:incoming_email).select(&:present?).map { |e| e.split("|") }.flatten.uniq
    end

    def category_email_in_regex
      @category_email_in_regex ||= Regexp.union Category.pluck(:email_in).select(&:present?).map { |e| e.split("|") }.flatten.uniq
    end

    def find_related_post(force: false)
      return if !force && SiteSetting.find_related_post_with_key && !sent_to_mailinglist_mirror?

      message_ids = Email::Receiver.extract_reply_message_ids(@mail, max_message_id_count: 5)
      return if message_ids.empty?

      host = Email::Sender.host_for(Discourse.base_url)
      post_id_regexp  = Regexp.new "topic/\\d+/(\\d+)@#{Regexp.escape(host)}"
      topic_id_regexp = Regexp.new "topic/(\\d+)@#{Regexp.escape(host)}"

      post_ids =  message_ids.map { |message_id| message_id[post_id_regexp, 1] }.compact.map(&:to_i)
      post_ids << Post.where(topic_id: message_ids.map { |message_id| message_id[topic_id_regexp, 1] }.compact, post_number: 1).pluck(:id)
      post_ids << EmailLog.where(message_id: message_ids).pluck(:post_id)
      post_ids << IncomingEmail.where(message_id: message_ids).pluck(:post_id)

      post_ids.flatten!
      post_ids.compact!
      post_ids.uniq!

      return if post_ids.empty?

      Post.where(id: post_ids).order(:created_at).last
    end

    def self.extract_reply_message_ids(mail, max_message_id_count:)
      message_ids = [mail.in_reply_to, Email::Receiver.extract_references(mail.references)]
      message_ids.flatten!
      message_ids.select!(&:present?)
      message_ids.uniq!
      message_ids.first(max_message_id_count)
    end

    def self.extract_references(references)
      if Array === references
        references
      elsif references.present?
        references.split(/[\s,]/).map { |r| r.tr("<>", "") }
      end
    end

    def likes
      @likes ||= Set.new ["+1", "<3", "❤", I18n.t('post_action_types.like.title').downcase]
    end

    def subscription_action_for(body, subject)
      return unless SiteSetting.unsubscribe_via_email
      return if sent_to_mailinglist_mirror?

      if ([subject, body].compact.map(&:to_s).map(&:downcase) & ['unsubscribe']).any?
        :confirm_unsubscribe
      end
    end

    def post_action_for(body)
      PostActionType.types[:like] if likes.include?(body.strip.downcase)
    end

    def create_topic(options = {})
      create_post_with_attachments(options)
    end

    def create_reply(options = {})
      raise TopicNotFoundError if options[:topic].nil? || options[:topic].trashed?
      options[:post] = nil if options[:post]&.trashed?

      if post_action_type = post_action_for(options[:raw])
        create_post_action(options[:user], options[:post], post_action_type)
      else
        raise TopicClosedError if options[:topic].closed?
        options[:topic_id] = options[:topic].id
        options[:reply_to_post_number] = options[:post]&.post_number
        options[:is_group_message] = options[:topic].private_message? && options[:topic].allowed_groups.exists?
        create_post_with_attachments(options)
      end
    end

    def create_post_action(user, post, type)
      PostActionCreator.new(user, post).perform(type)
    rescue PostAction::AlreadyActed
      # it's cool, don't care
    rescue Discourse::InvalidAccess => e
      raise InvalidPostAction.new(e)
    end

    def is_whitelisted_attachment?(attachment)
      attachment.content_type !~ SiteSetting.attachment_content_type_blacklist_regex &&
      attachment.filename !~ SiteSetting.attachment_filename_blacklist_regex
    end

    def attachments
      # strip blacklisted attachments (mostly signatures)
      @attachments ||= begin
        attachments =  @mail.attachments.select { |attachment| is_whitelisted_attachment?(attachment) }
        attachments << @mail if @mail.attachment? && is_whitelisted_attachment?(@mail)
        attachments
      end
    end

    def create_post_with_attachments(options = {})
      # deal with attachments
      options[:raw] = add_attachments(options[:raw], options[:user], options)

      create_post(options)
    end

    def add_attachments(raw, user, options = {})
      rejected_attachments = []
      attachments.each do |attachment|
        tmp = Tempfile.new(["discourse-email-attachment", File.extname(attachment.filename)])
        begin
          # read attachment
          File.open(tmp.path, "w+b") { |f| f.write attachment.body.decoded }
          # create the upload for the user
          opts = { for_group_message: options[:is_group_message] }
          upload = UploadCreator.new(tmp, attachment.filename, opts).create_for(user.id)
          if upload&.valid?
            # try to inline images
            if attachment.content_type&.start_with?("image/")
              if raw[attachment.url]
                raw.sub!(attachment.url, upload.url)
              elsif raw[/\[image:.*?\d+[^\]]*\]/i]
                raw.sub!(/\[image:.*?\d+[^\]]*\]/i, attachment_markdown(upload))
              else
                raw << "\n\n#{attachment_markdown(upload)}\n\n"
              end
            else
              raw << "\n\n#{attachment_markdown(upload)}\n\n"
            end
          else
            rejected_attachments << upload
            raw << "\n\n#{I18n.t('emails.incoming.missing_attachment', filename: upload.original_filename)}\n\n"
          end
        ensure
          tmp&.close!
        end
      end
      notify_about_rejected_attachment(rejected_attachments) if rejected_attachments.present? && !user.staged?

      raw
    end

    def notify_about_rejected_attachment(attachments)
      errors = []

      attachments.each do |a|
        error = a.errors.messages.values[0][0]
        errors << "#{a.original_filename}: #{error}"
      end

      message = Mail::Message.new(@mail)
      template_args = {
        former_title: message.subject,
        destination: message.to,
        site_name: SiteSetting.title,
        rejected_errors: errors.join("\n")
      }

      client_message = RejectionMailer.send_rejection(:email_reject_attachment, message.from, template_args)
      Email::Sender.new(client_message, :email_reject_attachment).send
    end

    def attachment_markdown(upload)
      if FileHelper.is_supported_image?(upload.original_filename)
        "<img src='#{upload.url}' width='#{upload.width}' height='#{upload.height}'>"
      else
        "<a class='attachment' href='#{upload.url}'>#{upload.original_filename}</a> (#{number_to_human_size(upload.filesize)})"
      end
    end

    def create_post(options = {})
      options[:via_email] = true
      options[:raw_email] = @raw_email

      # ensure posts aren't created in the future
      options[:created_at] ||= @mail.date
      if options[:created_at].nil?
        raise InvalidPost, "No post creation date found. Is the e-mail missing a Date: header?"
      end

      options[:created_at] = DateTime.now if options[:created_at] > DateTime.now

      is_private_message = options[:archetype] == Archetype.private_message ||
                           options[:topic].try(:private_message?)

      # only add elided part in messages
      if options[:elided].present? && (SiteSetting.always_show_trimmed_content || is_private_message)
        options[:raw] << Email::Receiver.elided_html(options[:elided])
      end

      if sent_to_mailinglist_mirror?
        options[:skip_validations] = true
        options[:skip_guardian] = true
      end

      user = options.delete(:user)
      result = NewPostManager.new(user, options).perform

      errors = result.errors.full_messages
      if errors.any? do |message|
           message.include?(I18n.t("activerecord.attributes.post.raw").strip) &&
           message.include?(I18n.t("errors.messages.too_short", count: SiteSetting.min_post_length).strip)
         end
        raise TooShortPost
      end
      raise InvalidPost, errors.join("\n") if result.errors.any?

      if result.post
        @incoming_email.update_columns(topic_id: result.post.topic_id, post_id: result.post.id)
        if result.post.topic && result.post.topic.private_message?
          add_other_addresses(result.post, user)
        end
      end

      result.post
    end

    def self.elided_html(elided)
      html =  "\n\n" << "<details class='elided'>" << "\n"
      html << "<summary title='#{I18n.t('emails.incoming.show_trimmed_content')}'>&#183;&#183;&#183;</summary>" << "\n\n"
      html << elided << "\n\n"
      html << "</details>" << "\n"
      html
    end

    def add_other_addresses(post, sender)
      %i(to cc bcc).each do |d|
        if @mail[d] && @mail[d].address_list && @mail[d].address_list.addresses
          @mail[d].address_list.addresses.each do |address_field|
            begin
              address_field.decoded
              email = address_field.address.downcase
              display_name = address_field.display_name.try(:to_s)
              next unless email["@"]
              if should_invite?(email)
                user = find_or_create_user(email, display_name)
                if user && can_invite?(post.topic, user)
                  post.topic.topic_allowed_users.create!(user_id: user.id)
                  TopicUser.auto_notification_for_staging(user.id, post.topic_id, TopicUser.notification_reasons[:auto_watch])
                  post.topic.add_small_action(sender, "invited_user", user.username)
                end
                # cap number of staged users created per email
                if @staged_users.count > SiteSetting.maximum_staged_users_per_email
                  post.topic.add_moderator_post(sender, I18n.t("emails.incoming.maximum_staged_user_per_email_reached"))
                  return
                end
              end
            rescue ActiveRecord::RecordInvalid, EmailNotAllowed
              # don't care if user already allowed or the user's email address is not allowed
            end
          end
        end
      end
    end

    def should_invite?(email)
      email !~ Email::Receiver.reply_by_email_address_regex &&
      email !~ group_incoming_emails_regex &&
      email !~ category_email_in_regex
    end

    def can_invite?(topic, user)
      !topic.topic_allowed_users.where(user_id: user.id).exists? &&
      !topic.topic_allowed_groups.where("group_id IN (SELECT group_id FROM group_users WHERE user_id = ?)", user.id).exists?
    end

    def send_subscription_mail(action, user)
      message = SubscriptionMailer.send(action, user)
      Email::Sender.new(message, :subscription).send
    end

    def delete_staged_users
      @staged_users.each do |user|
        if @incoming_email.user.id == user.id
          @incoming_email.update_columns(user_id: nil)
        end

        if user.posts.count == 0
          UserDestroyer.new(Discourse.system_user).destroy(user, quiet: true)
        end
      end
    end
  end

end
