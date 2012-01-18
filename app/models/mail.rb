class Mail
  attr_reader :page, :config, :data, :errors

  def initialize(page, config, data)
    @page, @config, @data = page, config.with_indifferent_access, data
    @required = @data.delete(:required)
    @errors = {}
  end

  def self.valid_config?(config)
    config_errors(config).empty?
  end
  
  def self.config_errors(config)
    config_errors = {}
    %w(recipients from).each do |required_field|
      if config[required_field].blank? and config["#{required_field}_field"].blank?
        config_errors[required_field] = "is required"
      end
    end
    config_errors
  end
  
  def self.config_error_messages(config)
    config_errors(config).collect do |field, message|
      "'#{field}' #{message}"
    end.to_sentence
  end

  def valid?
    unless defined?(@valid)
      @valid = true
      if recipients.blank? and !is_required_field?(config[:recipients_field])
        errors['form'] = 'Recipients are required.'
        @valid = false
      end

      if recipients.any?{|e| !valid_email?(e)}
        errors['form'] = 'Recipients are invalid.'
        @valid = false
      end

      if from.blank? and !is_required_field?(config[:from_field])
        errors['form'] = 'From is required.'
        @valid = false
      end

      if !valid_email?(from)
        errors['form'] = 'From is invalid.'
        @valid = false
      end

      if @required
        @required.each do |name, msg|
          if "as_email" == msg
            unless valid_email?(data[name])
              errors[name] = "invalid email address."
              @valid = false
            end
          elsif m = msg.match(/\/(.*)\//)
            regex = Regexp.new(m[1])
            unless data[name] =~ regex
              errors[name] = "doesn't match regex (#{m[1]})"
              @valid = false
            end
          else
            if data[name].blank?
              errors[name] = ((msg.blank? || %w(1 true required not_blank).include?(msg)) ? "is required." : msg)
              @valid = false
            end
          end
        end
      end
    end
    @valid
  end
  
  def from
    config[:from] || data[config[:from_field]]
  end

  def recipients
    res = config[:recipients]
    
    if !res
      res = data[config[:recipients_field]].split(/,/).collect{|e| e.strip}
      
      if res and config[:recipients_check_class] and config[:recipients_check_name] 
        clean_res = []
        check_exceptions = config[:recipients_check_exceptions] || []
        
        if config[:recipients_check_name] =~ /^[\w|\-]+$/
          res.each do |r|
            begin
              if check_exceptions.include?(r.downcase) or config[:recipients_check_class].constantize.find(:first, :conditions => ["lower(#{config[:recipients_check_name]}) LIKE ?", r.downcase])
                clean_res << r
              else
                Rails.logger.warn("Attempt to use email that didn't pass the check: #{r}.")
              end
            rescue Exception => e
              Rails.logger.warn("Attempt to use email that didn't pass the check: #{r}. Exception: #{e}")
            end
          end
        end
        
        res = clean_res
      end
    end
    
    res
  end

  def reply_to
    config[:reply_to] || data[config[:reply_to_field]]
  end

  def sender
    config[:sender]
  end

  def subject
    data[:subject] || config[:subject] || "Form Mail from #{page.request.host}"
  end
  
  def cc
    data[config[:cc_field]] || config[:cc] || ""
  end
  
  def files
    res = []
    data.each_value do |d|
      res << d if StringIO === d or Tempfile === d
    end
    res
  end
  
  def filesize_limit
    config[:filesize_limit] || 0
  end
  
  def plain_body
    return nil if not valid?
    @plain_body ||= (page.part( :email ) ? page.render_part( :email ) : page.render_part( :email_plain ))
  end
  
  def html_body
    return nil if not valid?
    @html_body = page.render_part( :email_html ) || nil
  end

  def send
    return false if not valid?

    if plain_body.blank? and html_body.blank?
      @plain_body = <<-EMAIL
The following information was posted:
#{data.to_hash.to_yaml}
      EMAIL
    end

    headers = { 'Reply-To' => reply_to || from }
    if sender
      headers['Return-Path'] = sender
      headers['Sender'] = sender
    end

    Mailer.deliver_generic_mail(
      :recipients => recipients,
      :from => from,
      :subject => subject,
      :plain_body => convert_encoding(@plain_body),
      :html_body => convert_encoding(@html_body),
      :cc => cc,
      :headers => headers,
      :files => files,
      :filesize_limit => filesize_limit
    )
    @sent = true
  rescue Exception => e
    errors['base'] = e.message
    @sent = false
  end

  def sent?
    @sent
  end

  protected

  def valid_email?(email)
    (email.blank? ? true : email =~ /^[^@]+@([^@.]+\.)[^@]+$/)
  end
  
  def is_required_field?(field_name)
    @required && @required.any? {|name,_| name == field_name}
  end

  def convert_encoding(str)
    # convert from iso-8859-15 to utf-8 in production
    if str and RAILS_ENV == 'production' and RUBY_VERSION < "1.9"
      begin
         str = Iconv.iconv('UTF-8', 'ISO-8859-15', str)
      rescue Iconv::IllegalSequence
         Rails.logger.warn("string #{str} of a mail message could not be processed")
      end
    end
    
    return str.to_s
  end
end
