# License: AGPL-3.0-or-later WITH Web-Template-Output-Additional-Permission-3.0-or-later
require 'httparty'
require 'digest/md5'

module Mailchimp
	include HTTParty
	format :json

  def self.base_uri(key)
    dc = get_datacenter(key)
    return "https://#{dc}.api.mailchimp.com/3.0"
  end

	# Run the configuration from an initializer
	# data: {:api_key => String}
	def self.config(hash)
		@options = {
			:headers => {
				'Content-Type' => 'application/json',
				'Accept' => 'application/json'
			}
		}
		@body = {
			:apikey => hash[:api_key]
		}
	end

  # Given a nonprofit mailchimp oauth2 key, return its current datacenter
  def self.get_datacenter(key)
    metadata = HTTParty.get('https://login.mailchimp.com/oauth2/metadata', {
      headers: { 
        'User-Agent' => 'oauth2-draft-v10',
        'Host' => 'login.mailchimp.com',
        'Accept' => 'application/json',
        'Authorization' => "OAuth #{key}"
      }
    })
    return metadata['dc']
  end

	def self.signup email, mailchimp_list_id
		body_hash = @body.merge({
			:id => mailchimp_list_id,
			:email => {:email => email}
		})
		post("/lists/subscribe", @options.merge(:body => body_hash.to_json)).parsed_response
  end

  def self.get_mailchimp_token(npo_id)
    mailchimp_token = QueryNonprofitKeys.get_key(npo_id, 'mailchimp_token')
    throw RuntimeError.new("No Mailchimp connection for this nonprofit: #{npo_id}") if mailchimp_token.nil?
    return mailchimp_token
  end

  # Given a nonprofit id and a list of tag master ids that they make into email lists,
  # create those email lists on mailchimp and return an array of hashes of mailchimp list ids, names, and tag_master_id
	def self.create_mailchimp_lists(npo_id, tag_master_ids)
    mailchimp_token = get_mailchimp_token(npo_id)
    uri = base_uri(mailchimp_token)
    puts "URI #{uri}"
    puts "KEY #{mailchimp_token}"

    npo = Qx.fetch(:nonprofits, npo_id).first
    tags = Qx.select("DISTINCT(tag_masters.name) AS tag_name, tag_masters.id")
      .from(:tag_masters)
      .where({"tag_masters.nonprofit_id" => npo_id})
      .and_where("tag_masters.id IN ($ids)", ids: tag_master_ids)
      .join(:nonprofits, "tag_masters.nonprofit_id = nonprofits.id")
      .execute

    tags.map do |h|
      list = post(uri+'/lists', {
        basic_auth: {username: '', password: mailchimp_token},
        headers: {'Content-Type' => 'application/json'},
        body: {
          name: 'CommitChange-'+h['tag_name'],
          contact: {
             company: npo['name'],
             address1: npo['address'] || '',
             city: npo['city'] || '',
             state: npo['state_code'] || '',
             zip: npo['zip_code'] || '',
             country: npo['state_code'] || '',
             phone: npo['phone'] || ''
           },
           permission_reminder: 'You are a registered supporter of our nonprofit.',
           campaign_defaults: {
             from_name: npo['name'] || '',
             from_email: npo['email'].blank? ?  "support@commichange.com" : npo['email'],
             subject: "Enter your subject here...",
             language: 'en'
           },
           email_type_option: false,
           visibility: 'prv'
        }.to_json
      })
      if list.code != 200
        raise Exception.new("Failed to create list: #{list}")
      end
      {id: list['id'], name: list['name'], tag_master_id: h['id']}
    end
  end

  # Given a nonprofit id and post_data, which is an array of batch operation hashes
  # See here: http://developer.mailchimp.com/documentation/mailchimp/guides/how-to-use-batch-operations/
  # Perform all the batch operations and return a status report 
  def self.perform_batch_operations(npo_id, post_data)
    return if post_data.empty?
    mailchimp_token = get_mailchimp_token(npo_id)
    uri = base_uri(mailchimp_token)
    batch_job_id = post(uri + '/batches',  {
      basic_auth: {username: "CommitChange", password: mailchimp_token},
      headers: {'Content-Type' => 'application/json'},
      body: {operations: post_data}.to_json
    })['id']
    check_batch_status(npo_id, batch_job_id)
  end

  def self.check_batch_status(npo_id, batch_job_id)
    mailchimp_token = get_mailchimp_token(npo_id)
    uri = base_uri(mailchimp_token)
    batch_status = get(uri+'/batches/'+batch_job_id, {
      basic_auth: {username: "CommitChange", password: mailchimp_token},
      headers: {'Content-Type' => 'application/json'}
    })
  end

  def self.delete_mailchimp_lists(npo_id, mailchimp_list_ids)
    mailchimp_token = get_mailchimp_token(npo_id)
    uri = base_uri(mailchimp_token)
    mailchimp_list_ids.map do |id|
      delete(uri + "/lists/#{id}", {basic_auth: {username: "CommitChange", password: mailchimp_token}})
    end
  end

  # `removed` and `added` are arrays of tag join ids that have been added or removed to a supporter
  def self.sync_supporters_to_list_from_tag_joins(npo_id, supporter_ids, tag_data)
    emails = Qx.select(:email).from(:supporters).where("id IN ($ids)", ids: supporter_ids).execute.map{|h| h['email']}
    to_add = get_mailchimp_list_ids(tag_data.select{|h| h['selected']}.map{|h| h['tag_master_id']})
    to_remove = get_mailchimp_list_ids(tag_data.reject{|h| h['selected']}.map{|h| h['tag_master_id']})
    return if to_add.empty? && to_remove.empty?

    bulk_post = emails.map{|em| to_add.map{|ml_id| {method: 'POST', path: "lists/#{ml_id}/members", body: {email_address: em, status: 'subscribed'}.to_json}}}.flatten
    bulk_delete = emails.map{|em| to_remove.map{|ml_id| {method: 'DELETE', path: "lists/#{ml_id}/members/#{Digest::MD5.hexdigest(em.downcase).to_s}"}}}.flatten
    perform_batch_operations(npo_id, bulk_post.concat(bulk_delete))
  end

  def self.get_mailchimp_list_ids(tag_master_ids)
    return [] if tag_master_ids.empty?
    to_insert_data = Qx.select("email_lists.mailchimp_list_id")
      .from(:tag_masters)
      .where("tag_masters.id IN ($ids)", ids: tag_master_ids)
      .join("email_lists", "email_lists.tag_master_id=tag_masters.id")
      .execute.map{|h| h['mailchimp_list_id']}
  end

end