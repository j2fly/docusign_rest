module DocusignRest

  class Client
    # Define the same set of accessors as the DocusignRest module
    attr_accessor *Configuration::VALID_CONFIG_KEYS
    attr_accessor :docusign_authentication_headers, :acct_id

    def initialize(options={})
      # Merge the config values from the module and those passed to the client.
      merged_options = DocusignRest.options.merge(options)

      # Copy the merged values to this client and ignore those not part
      # of our configuration
      Configuration::VALID_CONFIG_KEYS.each do |key|
        send("#{key}=", merged_options[key])
      end

      # Set up the DocuSign Authentication headers with the values passed from
      # our config block
      if access_token.nil?
        @docusign_authentication_headers = {
          "X-DocuSign-Authentication" => {
            "Username" => username,
            "Password" => password,
            "IntegratorKey" => integrator_key
          }.to_json
        }
      else
        @docusign_authentication_headers = {
          'Authorization' => "Bearer #{access_token}"
        }
      end

      # Set the account_id from the configure block if present, but can't call
      # the instance var @account_id because that'll override the attr_accessor
      # that is automatically configured for the configure block
      @acct_id = account_id
    end


    # Internal: sets the default request headers allowing for user overrides
    # via options[:headers] from within other requests. Additionally injects
    # the X-DocuSign-Authentication header to authorize the request.
    #
    # Client can pass in header options to any given request:
    # headers: {"Some-Key" => "some/value", "Another-Key" => "another/value"}
    #
    # Then we pass them on to this method to merge them with the other
    # required headers
    #
    # Example:
    #
    #   headers(options[:headers])
    #
    # Returns a merged hash of headers overriding the default Accept header if
    # the user passes in a new "Accept" header key and adds any other
    # user-defined headers along with the X-DocuSign-Authentication headers
    def headers(user_defined_headers={})
      default = {
        "Accept" => "json" #this seems to get added automatically, so I can probably remove this
      }

      default.merge!(user_defined_headers) if user_defined_headers

      @docusign_authentication_headers.merge(default)
    end


    # Internal: builds a URI based on the configurable endpoint, api_version,
    # and the passed in relative url
    #
    # url - a relative url requiring a leading forward slash
    #
    # Example:
    #
    #   build_uri("/login_information")
    #
    # Returns a parsed URI object
    def build_uri(url)
      URI.parse("#{endpoint}/#{api_version}#{url}")
    end


    # Internal: configures Net:HTTP with some default values that are required
    # for every request to the DocuSign API
    #
    # Returns a configured Net::HTTP object into which a request can be passed
    def initialize_net_http_ssl(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      # Explicitly verifies that the certificate matches the domain. Requires
      # that we use www when calling the production DocuSign API
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER

      http.ca_file = ca_file if ca_file

      http
    end

    def get_token(account_id, email, password)
      content_type = {"Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"}
      uri = build_uri("/oauth2/token")

      request = Net::HTTP::Post.new(uri.request_uri, content_type)
      request.body = "grant_type=password&client_id=#{integrator_key}&username=#{email}&password=#{password}&scope=api"

      http = initialize_net_http_ssl(uri)
      response = http.request(request)
      JSON.parse(response.body)
    end


    # Public: gets info necessary to make additional requests to the DocuSign API
    #
    # options - hash of headers if the client wants to override something
    #
    # Examples:
    #
    #   client = DocusignRest::Client.new
    #   response = client.login_information
    #   puts response.body
    #
    # Returns:
    #   accountId - For the username, password, and integrator_key specified
    #   baseUrl   - The base URL for all future DocuSign requests
    #   email     - The email used when signing up for DocuSign
    #   isDefault - # TODO identify what this is
    #   name      - The account name provided when signing up for DocuSign
    #   userId    - # TODO determine what this is used for, if anything
    #   userName  - Full name provided when signing up for DocuSign
    def get_login_information(options={})
      uri = build_uri("/login_information")
      request = Net::HTTP::Get.new(uri.request_uri, headers(options[:headers]))
      http = initialize_net_http_ssl(uri)
      http.request(request)
    end


    # Internal: uses the get_login_information method to determine the client's
    # accountId and then caches that value into an instance variable so we
    # don't end up hitting the API for login_information more than once per
    # request.
    #
    # This is used by the rake task in lib/tasks/docusign_task.rake to add
    # the config/initialzers/docusign_rest.rb file with the proper config block
    # which includes the account_id in it. That way we don't require hitting
    # the /login_information URI in normal requests
    #
    # Returns the accountId string
    def get_account_id
      unless @acct_id
        response = get_login_information.body
        hashed_response = JSON.parse(response)
        login_accounts = hashed_response['loginAccounts']
        @acct_id ||= login_accounts.first['accountId']
      end

      @acct_id
    end


    def check_embedded_signer(embedded, client_id)
      if embedded && embedded == true
        "\"clientUserId\" : \"#{client_id}\","
      end
    end


    # Internal: takes in an array of hashes of signers and concatenates all the
    # hashes with commas
    #
    # embedded -  Tells DocuSign if this is an embedded signer which determines
    #             weather or not to deliver emails. Also lets us authenticate
    #             them when they go to do embedded signing. Behind the scenes
    #             this is setting the clientUserId value to the signer's email.
    # name      - The name of the signer
    # email     - The email of the signer
    # role_name - The role name of the signer ('Attorney', 'Client', etc.).
    #
    # Returns a hash of users that need to be embedded in the template to
    # create an envelope
    def get_template_roles(signers)
      template_roles = []
      signers.each_with_index do |signer, index|
        template_role = {
          :name => signer[:name],
          :email => signer[:email],
          :roleName => signer[:role_name],
          :tabs => {
            :textTabs => get_signer_tabs(signer[:text_tabs]),
            :checkboxTabs => get_signer_tabs(signer[:checkbox_tabs])
          }
        }

        if signer[:email_notification].present?
          template_role[:emailNotification] = signer[:email_notification]
        end

        template_role['clientUserId'] = (signer[:client_id] || signer[:email]).to_s if signer[:embedded] == true 
        template_roles << template_role
      end
      template_roles
    end

    def get_signer_tabs(tabs)
      Array(tabs).map do |tab|
        {
          'tabLabel' => tab[:label],
          'name' => tab[:name],
          'value' => tab[:value],
          'documentId' => tab[:document_id],
          'selected' => tab[:selected]
        }
      end
    end

    def get_event_notification(event_notification)
      return {} unless event_notification
      {
        useSoapInterface: event_notification[:use_soap_interface] || false,
        includeCertificatWithSoap: event_notification[:include_certificate_with_soap] || false,
        url: event_notification[:url],
        loggingEnabled: event_notification[:logging],
        'EnvelopeEvents' => Array(event_notification[:envelope_events]).map do |envelope_event|
          {
            includeDocuments: envelope_event[:include_documents] || false,
            envelopeEventStatusCode: envelope_event[:envelope_event_status_code]
          }
        end
      }
    end


    # Internal: takes an array of hashes of signers required to complete a
    # document and allows for setting several options. Not all options are
    # currently dynamic but that's easy to change/add which I (and I'm
    # sure others) will be doing in the future.
    #
    # template           - Includes other optional fields only used when
    #                      being called from a template
    # email              - The signer's email
    # name               - The signer's name
    # embedded           - Tells DocuSign if this is an embedded signer which
    #                      determines weather or not to deliver emails. Also
    #                      lets us authenticate them when they go to do
    #                      embedded signing. Behind the scenes this is setting
    #                      the clientUserId value to the signer's email.
    # email_notification - Send an email or not
    # role_name          - The signer's role, like 'Attorney' or 'Client', etc.
    # template_locked    - Doesn't seem to work/do anything
    # template_required  - Doesn't seem to work/do anything
    # anchor_string      - The string of text to anchor the 'sign here' tab to
    # document_id        - If the doc you want signed isn't the first doc in
    #                      the files options hash
    # page_number        - Page number of the sign here tab
    # x_position         - Distance horizontally from the anchor string for the
    #                      'sign here' tab to appear. Note: doesn't seem to
    #                      currently work.
    # y_position         - Distance vertically from the anchor string for the
    #                      'sign here' tab to appear. Note: doesn't seem to
    #                      currently work.
    # sign_here_tab_text - Instead of 'sign here'. Note: doesn't work
    # tab_label          - TODO: figure out what this is
    def get_signers(signers, options={})
      doc_signers = []


      signers.each_with_index do |signer, index|
        doc_signer = {
          :email => signer[:email],
          :name => signer[:name],
          :accessCode => "",
          :addAccessCodeToEmail =>  false,
          :customFields => nil,
          :iDCheckConfigurationName => nil,
          :iDCheckInformationInput => nil,
          :inheritEmailNotificationConfiguration => false,
          :note => "",
          :phoneAuthentication => nil,
          :recipientAttachment => nil,
          :recipientId => index+1,
          :requireIdLookup => false,
          :roleName => signer[:role_name],
          :routingOrder => index+1,
          :socialAuthentications => nil
        }

        if signer[:email_notification].present?
          doc_signer[:emailNotification] = signer[:email_notification]
        end

        if signer[:embedded]
          doc_signer[:clientUserId] = signer[:client_id] || signer[:email]
        end

        if options[:template] == true
          doc_signer[:templateAccessCodeRequired] = false
          doc_signer[:templateLocked] = signer[:template_locked].nil? ? true : signer[:template_locked]
          doc_signer[:templateRequired] = signer[:template_required].nil? ? true : signer[:template_required]
        end

        doc_signer[:autoNavigation] = false
        doc_signer[:defaultRecipient] = false
        doc_signer[:signatureInfo] = nil
        doc_signer[:tabs] = {}
        doc_signer[:tabs][:approveTabs] = nil
        doc_signer[:tabs][:checkboxTabs] = nil
        doc_signer[:tabs][:companyTabs] = nil
        doc_signer[:tabs][:dateSignedTabs] = get_tabs(signer[:date_signed_tabs], options, index)
        doc_signer[:tabs][:dateTabs] = nil
        doc_signer[:tabs][:declineTabs] = nil
        doc_signer[:tabs][:emailTabs] = get_tabs(signer[:email_tabs], options, index)
        doc_signer[:tabs][:envelopeIdTabs] = nil
        doc_signer[:tabs][:fullNameTabs] = get_tabs(signer[:full_name_tabs], options, index)
        doc_signer[:tabs][:listTabs] = nil
        doc_signer[:tabs][:noteTabs] = nil
        doc_signer[:tabs][:numberTabs] = nil
        doc_signer[:tabs][:radioGroupTabs] = nil
        doc_signer[:tabs][:initialHereTabs] = get_tabs(signer[:initial_here_tabs], options, index)
        doc_signer[:tabs][:signHereTabs] = get_tabs(signer[:sign_here_tabs], options, index)
        doc_signer[:tabs][:signerAttachmentTabs] = nil
        doc_signer[:tabs][:ssnTabs] = nil
        doc_signer[:tabs][:textTabs] = get_tabs(signer[:text_tabs], options, index)
        doc_signer[:tabs][:titleTabs] = nil
        doc_signer[:tabs][:zipTabs] = nil

        # append the fully build string to the array
        doc_signers << doc_signer
      end
      doc_signers.to_json
    end

    def get_tabs(tabs, options, index)
      tab_array = []

      tab_buffers = Array(tabs).map do |tab|
        tab_hash = {}

        tab_hash[:anchorString] = tab[:anchor_string]
        tab_hash[:anchorXOffset] = tab[:anchor_x_offset] || '0'
        tab_hash[:anchorYOffset] = tab[:anchor_y_offset] || '0'
        tab_hash[:anchorIgnoreIfNotPresent] = tab[:ignore_anchor_if_not_present] || false
        tab_hash[:anchorUnits] = "pixels"
        tab_hash[:conditionalParentLabel] = nil
        tab_hash[:conditionalParentValue] = nil
        tab_hash[:documentId] = tab[:document_id] || '1'
        tab_hash[:pageNumber] = tab[:page_number] || '1'
        tab_hash[:recipientId] = index+1
        tab_hash[:required] = tab[:required] || false

        if options[:template] == true
          tab_hash[:templateLocked] = tab[:template_locked].nil? ? true : tab[:template_locked]
          tab_hash[:templateRequired] = tab[:template_required].nil? ? true : tab[:template_required]
        end

        tab_hash[:xPosition] = tab[:x_position] || '0'
        tab_hash[:yPosition] = tab[:y_position] || '0'
        tab_hash[:name] = tab[:name] || 'Sign Here'
        tab_hash[:optional] = false
        tab_hash[:scaleValue] = 1
        tab_hash[:tabLabel] = tab[:label] || 'Signature 1'

        tab_array << tab_hash
      end
      tab_array
    end

    # Internal: sets up the file ios array
    #
    # files - a hash of file params
    #
    # Returns the properly formatted ios used to build the file_params hash
    def create_file_ios(files)
      # UploadIO is from the multipart-post gem's lib/composite_io.rb:57
      # where it has this documentation:
      #
      # ********************************************************************
      # Create an upload IO suitable for including in the params hash of a
      # Net::HTTP::Post::Multipart.
      #
      # Can take two forms. The first accepts a filename and content type, and
      # opens the file for reading (to be closed by finalizer).
      #
      # The second accepts an already-open IO, but also requires a third argument,
      # the filename from which it was opened (particularly useful/recommended if
      # uploading directly from a form in a framework, which often save the file to
      # an arbitrarily named RackMultipart file in /tmp).
      #
      # Usage:
      #
      #     UploadIO.new("file.txt", "text/plain")
      #     UploadIO.new(file_io, "text/plain", "file.txt")
      # ********************************************************************
      #
      # There is also a 4th undocumented argument, opts={}, which allows us
      # to send in not only the Content-Disposition of 'file' as required by
      # DocuSign, but also the documentId parameter which is required as well
      #
      ios = []
      files.each_with_index do |file, index|
        ios << UploadIO.new(
                 file[:io] || file[:path],
                 file[:content_type] || "application/pdf",
                 file[:name],
                 "Content-Disposition" => "file; documentid=#{index+1}"
               )
      end
      ios
    end


    # Internal: sets up the file_params for inclusion in a multipart post request
    #
    # ios - An array of UploadIO formatted file objects
    #
    # Returns a hash of files params suitable for inclusion in a multipart
    # post request
    def create_file_params(ios)
      # multi-doc uploading capabilities, each doc needs to be it's own param
      file_params = {}
      ios.each_with_index do |io,index|
        file_params.merge!("file#{index+1}" => io)
      end
      file_params
    end


    # Internal: takes in an array of hashes of documents and calculates the
    # documentId then concatenates all the hashes with commas
    #
    # Returns a hash of documents that are to be uploaded
    def get_documents(ios)
      documents = []
      ios.each_with_index do |io, index|
        documents << "{
          \"documentId\" : \"#{index+1}\",
          \"name\"       : \"#{io.original_filename}\"
        }"
      end
      documents.join(",")
    end


    # Internal sets up the Net::HTTP request
    #
    # uri         - The fully qualified final URI
    # post_body   - The custom post body including the signers, etc
    # file_params - Formatted hash of ios to merge into the post body
    # headers     - Allows for passing in custom headers
    #
    # Returns a request object suitable for embedding in a request
    def initialize_net_http_multipart_post_request(uri, post_body, file_params, headers)
      # Net::HTTP::Post::Multipart is from the multipart-post gem's lib/multipartable.rb
      #
      # path       - The fully qualified URI for the request
      # params     - A hash of params (including files for uploading and a
      #              customized request body)
      # headers={} - The fully merged, final request headers
      # boundary   - Optional: you can give the request a custom boundary
      #
      request = Net::HTTP::Post::Multipart.new(
        uri.request_uri,
        {post_body: post_body}.merge(file_params),
        headers
      )

      # DocuSign requires that we embed the document data in the body of the
      # JSON request directly so we need to call ".read" on the multipart-post
      # provided body_stream in order to serialize all the files into a
      # compatible JSON string.
      request.body = request.body_stream.read
      request
    end


    # Public: creates an envelope from a document directly without a template
    #
    # file_io       - Optional: an opened file stream of data (if you don't
    #                 want to save the file to the file system as an incremental
    #                 step)
    # file_path     - Required if you don't provide a file_io stream, this is
    #                 the local path of the file you wish to upload. Absolute
    #                 paths recommended.
    # file_name     - The name you want to give to the file you are uploading
    # content_type  - (for the request body) application/json is what DocuSign
    #                 is expecting
    # email_subject - (Optional) short subject line for the email
    # email_body    - (Optional) custom text that will be injected into the
    #                 DocuSign generated email
    # signers       - A hash of users who should receive the document and need
    #                 to sign it. More info about the options available for
    #                 this method are documented above it's method definition.
    # status        - Options include: 'sent', 'created', 'voided' and determine
    #                 if the envelope is sent out immediately or stored for
    #                 sending at a later time
    # headers       - Allows a client to pass in some
    #
    # Returns a JSON parsed response object containing:
    #   envelopeId     - The envelope's ID
    #   status         - Sent, created, or voided
    #   statusDateTime - The date/time the envelope was created
    #   uri            - The relative envelope uri
    def create_envelope_from_document(options={})
      ios = create_file_ios(options[:files])
      file_params = create_file_params(ios)

      post_body = "{
        \"emailBlurb\"   : \"#{options[:email][:body] if options[:email]}\",
        \"emailSubject\" : \"#{options[:email][:subject] if options[:email]}\",
        \"documents\"    : [#{get_documents(ios)}],
        \"recipients\"   : {
          \"signers\" : #{get_signers(options[:signers])}
        },
        \"status\"       : \"#{options[:status]}\"
      }
      "

      uri = build_uri("/accounts/#{@acct_id}/envelopes")

      http = initialize_net_http_ssl(uri)

      request = initialize_net_http_multipart_post_request(
                  uri, post_body, file_params, headers(options[:headers])
                )

      # Finally do the Net::HTTP request!
      response = http.request(request)
      parsed_response = JSON.parse(response.body)
    end


    # Public: allows a template to be dynamically created with several options.
    #
    # files         - An array of hashes of file parameters which will be used
    #                 to create actual files suitable for upload in a multipart
    #                 request.
    #
    #                 Options: io, path, name. The io is optional and would
    #                 require creating a file_io object to embed as the first
    #                 argument of any given file hash. See the create_file_ios
    #                 method definition above for more details.
    #
    # email/body    - (Optional) sets the text in the email. Note: the envelope
    #                 seems to override this, not sure why it needs to be
    #                 configured here as well. I usually leave it blank.
    # email/subject - (Optional) sets the text in the email. Note: the envelope
    #                 seems to override this, not sure why it needs to be
    #                 configured here as well. I usually leave it blank.
    # signers       - An array of hashes of signers. See the
    #                 get_signers method definition for options.
    # description   - The template description
    # name          - The template name
    # headers       - Optional hash of headers to merge into the existing
    #                 required headers for a multipart request.
    #
    # Returns a JSON parsed response body containing the template's:
    #   name - Name given above
    #   templateId - The auto-generated ID provided by DocuSign
    #   Uri - the URI where the template is located on the DocuSign servers
    def create_template(options={})
      ios = create_file_ios(options[:files])
      file_params = create_file_params(ios)

      post_body = "{
        \"emailBlurb\"   : \"#{options[:email][:body] if options[:email]}\",
        \"emailSubject\" : \"#{options[:email][:subject] if options[:email]}\",
        \"documents\"    : [#{get_documents(ios)}],
        \"recipients\"   : {
          \"signers\"    : #{get_signers(options[:signers], template: true)}
        },
        \"envelopeTemplateDefinition\" : {
          \"description\" : \"#{options[:description]}\",
          \"name\"        : \"#{options[:name]}\",
          \"pageCount\"   : 1,
          \"password\"    : \"\",
          \"shared\"      : false
        }
      }
      "

      uri = build_uri("/accounts/#{@acct_id}/templates")

      http = initialize_net_http_ssl(uri)

      request = initialize_net_http_multipart_post_request(
                  uri, post_body, file_params, headers(options[:headers])
                )

      # Finally do the Net::HTTP request!
      response = http.request(request)
      JSON.parse(response.body)
    end

    def get_template(template_id, options = {})
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      uri = build_uri("/accounts/#{@acct_id}/templates/#{template_id}")

      http = initialize_net_http_ssl(uri)
      request = Net::HTTP::Get.new(uri.request_uri, headers(content_type))
      response = http.request(request)
      JSON.parse(response.body)
    end


    # Public: create an envelope for delivery from a template
    #
    # headers        - Optional hash of headers to merge into the existing
    #                  required headers for a POST request.
    # status         - Options include: 'sent', 'created', 'voided' and
    #                  determine if the envelope is sent out immediately or
    #                  stored for sending at a later time
    # email/body     - Sets the text in the email body
    # email/subject  - Sets the text in the email subject line
    # template_id    - The id of the template upon which we want to base this
    #                  envelope
    # template_roles - See the get_template_roles method definition for a list
    #                  of options to pass. Note: for consistency sake we call
    #                  this 'signers' and not 'templateRoles' when we build up
    #                  the request in client code.
    # headers        - Optional hash of headers to merge into the existing
    #                  required headers for a multipart request.
    #
    # Returns a JSON parsed response body containing the envelope's:
    #   name - Name given above
    #   templateId - The auto-generated ID provided by DocuSign
    #   Uri - the URI where the template is located on the DocuSign servers
    def create_envelope_from_template(options={})
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      post_body = {
        :status => options[:status],
        :emailBlurb => options[:email][:body],
        :emailSubject => options[:email][:subject],
        :templateId => options[:template_id],
        :eventNotification => get_event_notification(options[:event_notification]),
        :templateRoles => get_template_roles(options[:signers])
       }.to_json

      uri = build_uri("/accounts/#{@acct_id}/envelopes")

      http = initialize_net_http_ssl(uri)

      request = Net::HTTP::Post.new(uri.request_uri, headers(content_type))
      request.body = post_body

      response = http.request(request)
      parsed_response = JSON.parse(response.body)
    end


    # Public returns the URL for embedded signing
    #
    # envelope_id - the ID of the envelope you wish to use for embedded signing
    # name        - the name of the signer
    # email       - the email of the recipient
    # return_url  - the URL you want the user to be directed to after he or she
    #               completes the document signing
    # headers     - optional hash of headers to merge into the existing
    #               required headers for a multipart request.
    #
    # Returns the URL string for embedded signing (can be put in an iFrame)
    def get_recipient_view(options={})
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      post_body = {
        :authenticationMethod => 'email',
        :clientUserId => options[:client_id] || options[:email],
        :email => options[:email],
        :returnUrl => options[:return_url],
        :userName => options[:name]
       }.to_json

      uri = build_uri("/accounts/#{@acct_id}/envelopes/#{options[:envelope_id]}/views/recipient")

      http = initialize_net_http_ssl(uri)

      request = Net::HTTP::Post.new(uri.request_uri, headers(content_type))
      request.body = post_body

      response = http.request(request)
      JSON.parse(response.body)
    end

    # Public returns the envelope recipients for a given envelope
    #
    # include_tabs - boolean, determines if the tabs for each signer will be
    #                returned in the response, defaults to false.
    # envelope_id  - ID of the envelope for which you want to retrive the
    #                signer info
    # headers      - optional hash of headers to merge into the existing
    #                required headers for a multipart request.
    #
    # Returns a hash of detailed info about the envelope including the signer
    # hash and status of each signer
    def get_envelope_recipients(options={})
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      include_tabs = options[:include_tabs] || false
      include_extended = options[:include_extended] || false
      uri = build_uri("/accounts/#{@acct_id}/envelopes/#{options[:envelope_id]}/recipients?include_tabs=#{include_tabs}&include_extended=#{include_extended}")

      http = initialize_net_http_ssl(uri)
      request = Net::HTTP::Get.new(uri.request_uri, headers(content_type))
      response = http.request(request)
      parsed_response = JSON.parse(response.body)
    end

    # Public retrieves the attached file from a given envelope
    #
    # envelope_id      - ID of the envelope from which the doc will be retrieved
    # document_id      - ID of the document to retrieve
    # local_save_path  - Local absolute path to save the doc to including the
    #                    filename itself
    # headers          - Optional hash of headers to merge into the existing
    #                    required headers for a multipart request.
    #
    # Example
    #
    #   client.get_document_from_envelope(
    #     envelope_id: @envelope_response["envelopeId"],
    #     document_id: 1,
    #     local_save_path: 'docusign_docs/file_name.pdf'
    #   )
    #
    # Returns the PDF document as a byte stream.
    def get_document_from_envelope(options={})
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      uri = build_uri("/accounts/#{@acct_id}/envelopes/#{options[:envelope_id]}/documents/#{options[:document_id]}")

      http = initialize_net_http_ssl(uri)
      request = Net::HTTP::Get.new(uri.request_uri, headers(content_type))
      http.request(request)
    end

    def create_account(options)
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      uri = build_uri("/accounts")

      post_body = convert_hash_keys(options).to_json

      http = initialize_net_http_ssl(uri)
      request = Net::HTTP::Post.new(uri.request_uri, headers(content_type))
      request.body = post_body
      response = http.request(request)
      JSON.parse(response.body)
    end

    def delete_account(account_id, options = {})
      content_type = {'Content-Type' => 'application/json'}
      content_type.merge(options[:headers]) if options[:headers]

      uri = build_uri("/accounts/#{account_id}")

      http = initialize_net_http_ssl(uri)
      request = Net::HTTP::Delete.new(uri.request_uri, headers(content_type))
      response = http.request(request)
      json = response.body
      json = "{}" if json.nil? || json == ""
      JSON.parse(json)
    end

    def convert_hash_keys(value)
      case value
        when Array
          value.map { |v| convert_hash_keys(v) }
        when Hash
          Hash[value.map { |k, v| [k.to_s.camelize(:lower), convert_hash_keys(v)] }]
        else
          value
       end
    end    
  end

end
