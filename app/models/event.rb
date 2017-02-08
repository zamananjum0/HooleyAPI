class Event < ApplicationRecord
  
  include JsonBuilder
  include PgSearch
  
  belongs_to :member_profile
  has_many   :event_attachments, dependent: :destroy
  has_many   :event_co_hosts,    dependent: :destroy
  has_many   :event_hash_tags,   dependent: :destroy
  has_many   :hashtags, through: :event_hash_tags
  has_many   :event_members,     dependent: :destroy
  has_many   :synchronizations, as: :media
  has_many   :posts

  validates_presence_of :event_name, :start_date, :end_date, :location, :longitude, :latitude, :category_id
  accepts_nested_attributes_for :event_members, :event_co_hosts, :event_attachments, :hashtags
  
  @@limit           = 3
  @@current_profile = nil

  acts_as_mappable default_units: :kms, lat_column_name: :latitude, lng_column_name: :longitude
  pg_search_scope :search_by_title,
    against: [:event_name, :event_details],
    using: {
        tsearch: {
            any_word: true,
            dictionary: "english"
        }
    }

  def self.event_create(data, current_user)
    begin
      sync_event_id = 0
      data    = data.with_indifferent_access
      profile = current_user.profile
      event   = profile.events.build(data[:event])
      if event.save
        data[:hash_tags].each do |tag|
          hash_tag = Hashtag.find_by_name(tag[:tag_name])
          if hash_tag.present?
            hash_tag.count = hash_tag.count + 1
            hash_tag.save!
          else
            hash_tag = Hashtag.create name: tag[:tag_name]
          end
          event_hash_tag = EventHashTag.find_by_event_id_and_hashtag_id(event.id, hash_tag.id)
          if not event_hash_tag.present?
            event_hash_tag            = event.event_hash_tags.build
            event_hash_tag.hashtag_id = hash_tag.id
            event_hash_tag.save
          end
        end
        sync_event_id   = event.id
        resp_data       = ''
        resp_status     = 1
        resp_message    = 'Event Created'
        resp_errors     = ''
      else
        resp_data       = ''
        resp_status     = 0
        resp_message    = 'Errors'
        resp_errors     = event.errors.messages
      end
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id = data[:request_id]
    response = JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
    [response, sync_event_id]
  end
  
  def self.event_sync_to_members(event_id, current_user)
    events = Event.where(id: event_id)
    # Sync to current user
    make_event_sync_response(current_user, events)
    
    member_profile_ids  = []
    member_profile_ids << events.first.event_members.pluck(:member_profile_id)
    
    # Followers
    # member_profile_ids << MemberFollowing.where("following_profile_id = ? AND following_status = ? ", current_user.profile_id, AppConstants::ACCEPTED).pluck(:member_profile_id)
   
    users = User.where(profile_id: member_profile_ids.flatten.uniq)
    users && users.each do |user|
      if user != current_user
        make_event_sync_response(user, events)
      end
    end
  end

  def self.make_event_sync_response(user, events)
    sync_object                   = events.first.synchronizations.build
    sync_object.member_profile_id = user.profile_id
    sync_object.sync_token        = SecureRandom.uuid
    sync_object.synced_date       = events.first.updated_at
    sync_object.save!
  
    resp_data       = events_response(events, sync_object.sync_token)
    resp_status     = 1
    resp_request_id = ''
    resp_message    = 'Events'
    resp_errors     = ''
    response        = JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, type: "Sync")
    ProfileJob.perform_later response, user.id
  end

  def self.events_response(events, sync_token=nil)
    events = events.as_json(
        only: [:id, :event_name, :member_profile_id, :location, :latitude, :longitude, :radius, :event_details, :is_frields_allowed, :is_public, :is_paid, :category_id, :event_type, :start_date, :end_date, :created_at, :updated_at],
        include:{
            event_attachments:{
                only:[:id, :event_id, :attachment_type, :message, :attachment_url, :thumbnail_url, :poster_skin]
            },
            event_co_hosts:{
                only:[:id, :event_id, :member_profile_id]
            },
            hashtags:{
                only:[:id, :name]
            },
            event_members:{
                only: [:id],
                include:{
                    member_profile: {
                        only: [:id, :photo],
                        include: {
                            user: {
                                only: [:id, :first_name, :last_name]
                            }
                        }
                    }
                }
            }
        }
    )
  
    if sync_token.present?
      { events: events }.as_json.merge!(sync_token: sync_token)
    else
      { events: events }.as_json
    end

  end

  def self.show_event(data, current_user)
    begin
      data  = data.with_indifferent_access
      event = Event.find_by_id(data[:event][:id])
      resp_data       = event_response(event)
      resp_status     = 1
      resp_message    = 'Event details'
      resp_errors     = ''
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.event_response(event)
    event = event.as_json(
        only:    [:id, :name, :country_id, :city_id, :organization, :location, :description, :cost, :camp_website, :start_date, :end_date, :upload, :member_profile_id, :created_at, :updated_at]
    )
  
    events_array = []
    events_array << event
  
    { events: events_array }.as_json
  end

  def self.event_list(data, current_user)
    begin
      data = data.with_indifferent_access
      per_page = (data[:per_page] || @@limit).to_i
      page     = (data[:page] || 1).to_i
      if data[:type].present? && data[:type] == 'upcoming'
        # List
        events              = Event.where('Date(start_date)  >= ?', Date.today)
        today_events        = events.where('Date(start_date) = ?',  Date.today)
        a_day_after_events  = events.where('Date(start_date) = ?',  Date.today + 1.day)
        next_week_events    = events.where('Date(start_date) > ? AND Date(start_date) <= ?', Date.today + 1.day, Date.today + 1.week)
        upcoming_events     = events.where('Date(start_date) > ?', Date.today + 1.week)

        today_events      = today_events.page(page.to_i).per_page(per_page.to_i)
        today_paging_data = JsonBuilder.get_paging_data(page, per_page, today_events)

        a_day_after_events      = a_day_after_events.page(page.to_i).per_page(per_page.to_i)
        a_day_after_paging_data = JsonBuilder.get_paging_data(page, per_page, a_day_after_events)

        next_week_events      = next_week_events.page(page.to_i).per_page(per_page.to_i)
        next_week_paging_data = JsonBuilder.get_paging_data(page, per_page, next_week_events)
        
        upcoming_events      = upcoming_events.page(page.to_i).per_page(per_page.to_i)
        upcoming_paging_data = JsonBuilder.get_paging_data(page, per_page, upcoming_events)
        
        resp_data = event_list_response(today_events, a_day_after_events, next_week_events, upcoming_events, 'upcoming', today_paging_data, a_day_after_paging_data, next_week_paging_data, upcoming_paging_data)
      elsif data[:type].present? && data[:type] == 'past'
        # List
        events              = Event.where('Date(start_date) <= ?', Date.today - 1.day)
        yesterday_events    = events.where('Date(start_date) = ?',  Date.today - 1.day)
        a_day_before_events = events.where('Date(start_date) = ?',  Date.today - 2.day)
        last_week_events    = events.where('Date(start_date) >= ? AND Date(start_date) < ?', Date.today - 1.week, Date.today - 2.day)
        previous_events     = events.where('Date(start_date) < ?', Date.today - 1.week)

        yesterday_events      = yesterday_events.page(page.to_i).per_page(per_page.to_i)
        yesterday_paging_data = JsonBuilder.get_paging_data(page, per_page, yesterday_events)

        a_day_before_events      = a_day_before_events.page(page.to_i).per_page(per_page.to_i)
        a_day_before_paging_data = JsonBuilder.get_paging_data(page, per_page, a_day_before_events)

        last_week_events         = last_week_events.page(page.to_i).per_page(per_page.to_i)
        last_week_paging_data    = JsonBuilder.get_paging_data(page, per_page, last_week_events)

        previous_events          = previous_events.page(page.to_i).per_page(per_page.to_i)
        previous_paging_data = JsonBuilder.get_paging_data(page, per_page, previous_events)
        
        resp_data = event_list_response(yesterday_events, a_day_before_events, last_week_events, previous_events, 'past', yesterday_paging_data, a_day_before_paging_data, last_week_paging_data, previous_paging_data)
      elsif data[:type].present? && data[:type] == 'search'
        # Search
        events  = Event.all
        if data[:keyword].present?
          events = events.search_by_title(data[:keyword])
        end
        
        if data[:date].present?
          events = events.where('Date(start_date) = ?', data[:date])
        end

        if data[:location].present?
          events = events.where('lower(location) like ?', data[:location])
        end
        
        if data[:radius].present? && data[:latitude].present? && data[:longitude].present?
          events = events.within(data[:radius], :origin => [data[:latitude], data[:longitude]])
        end

        if data[:category_id].present?
          events = events.where(category_id: data[:category_id])
        end
        
        if data[:is_paid].present?
          if data[:is_paid] == 'free'
            events = events.where(is_paid: false)
          elsif data[:is_paid] == 'paid'
            events = events.where(is_paid: true)
          end
        end
        events  =  events.page(page.to_i).per_page(per_page.to_i)
        paging_data = JsonBuilder.get_paging_data(page, per_page, events)
        events = events.as_json(
            only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
            include:{
                event_attachments:{
                    only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
                }
            }
        )
        resp_data       = {events: events}.as_json
      end
      resp_status     = 1
      resp_message    = 'Event list'
      resp_errors     = ''
      resp_request_id = ''
      resp_request_id = data[:request_id] if data[:request_id].present?
      if data[:type] == 'search'
        JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
      else
        JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
      end
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      resp_message    = 'error'
      resp_errors     = e
      resp_request_id = ''
      resp_request_id = data[:request_id] if data[:request_id].present?
      JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
    end
  end

  def self.event_list_response(day_events, np_day_events, week_events, remaining_events, type, today_paging_data, np_paging_data, week_paging_data, remaining_paging_data)
    day_events = day_events.as_json(
       only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
       include:{
           event_attachments:{
               only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
           }
       }
    )
    np_day_events = np_day_events.as_json(
        only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
        include:{
            event_attachments:{
                only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
            }
        }
    )
    week_events = week_events.as_json(
        only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
        include:{
            event_attachments:{
                only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
            }
        }
    )
    remaining_events = remaining_events.as_json(
        only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
        include:{
            event_attachments:{
                only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
            }
        }
    )
        
    if type == 'upcoming'
      today_events_resp       = {events: day_events, paging_data:       today_paging_data}.as_json
      a_day_after_events_resp = {events: np_day_events, paging_data:    np_paging_data}.as_json
      next_week_events_resp   = {events: week_events, paging_data:      week_paging_data}.as_json
      upcoming_events_resp    = {events: remaining_events, paging_data: remaining_paging_data}.as_json
      {
        today_events:       today_events_resp,
        a_day_after_events: a_day_after_events_resp,
        next_week_events:   next_week_events_resp,
        upcoming_events:    upcoming_events_resp
      }.as_json
    else
      yesterday_events_resp    = {events: day_events, paging_data:       today_paging_data}.as_json
      a_day_before_events_resp = {events: np_day_events, paging_data: np_paging_data}.as_json
      last_week_events_resp    = {events: week_events, paging_data:      week_paging_data}.as_json
      previous_events_resp     = {events: remaining_events, paging_data:  remaining_paging_data}.as_json
      {
          yesterday_events:    yesterday_events_resp,
          a_day_before_events: a_day_before_events_resp,
          last_week_events:    last_week_events_resp,
          previous_events:     previous_events_resp
      }.as_json
    end
  end
  
  def self.event_list_horizontal(data, current_user)
    begin
      data  =  data.with_indifferent_access
      if data[:type].present? && data[:type] == 'search'
        response = search_event_list(data)
      elsif data[:list_type].present? && data[:list_type]    == 'day'
        response = day_event_list(data)
      elsif data[:list_type].present? && data[:list_type] == 'np_day'
        response = np_event_list(data)
      elsif data[:list_type].present? && data[:list_type] == 'week'
        response = week_event_list(data)
      elsif data[:list_type].present? && data[:list_type] == 'all'
        response = all_event_list(data)
      end
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      resp_message    = 'error'
      resp_errors     = e
      resp_request_id   = data[:request_id]
      JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
    end
  end
  
  def self.search_event_list(data)
    per_page = (data[:per_page] || @@limit).to_i
    page     = (data[:page] || 1).to_i
    
    if data[:keyword].present?
      events = Event.search_by_title(data[:keyword])
    end
    if data[:date].present?
      events = events.where('Date(start_date) = ?', data[:date])
    end
    if data[:location].present?
      events = events.where('lower(location) like ?', data[:location])
    end
    if data[:radius].present? && data[:latitude].present? && data[:longitude].present?
      events = events.within(data[:radius], :origin => [data[:latitude], data[:longitude]])
    end
    if data[:category_id].present?
      events = events.where(category_id: data[:category_id])
    end
    if data[:is_paid].present?
      if data[:is_paid] == 'free'
        events = events.where(is_paid: false)
      elsif data[:is_paid] == 'paid'
        events = events.where(is_paid: true)
      end
    end
    
    events  =  events.page(page.to_i).per_page(per_page.to_i)
    paging_data = JsonBuilder.get_paging_data(page, per_page, events)
    events = events.as_json(
        only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
        include:{
            event_attachments:{
                only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
            }
        }
    )
    resp_data       = {events: events}.as_json
    resp_status     = 1
    resp_message    = 'Event list'
    resp_errors     = ''
    resp_request_id = ''
    resp_request_id = data[:request_id] if data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end
  
  def self.day_event_list(data)
    per_page = (data[:per_page] || @@limit).to_i
    page     = (data[:page] || 1).to_i
    
    if data[:type] == 'upcoming'
      today_events  = Event.where('Date(start_date) = ?',  Date.today)
      today_events  =  today_events.page(page.to_i).per_page(per_page.to_i)
      paging_data   =  JsonBuilder.get_paging_data(page, per_page, today_events)
      today_events  =  today_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: today_events, paging_data: paging_data}.as_json
      resp_data       = {today_events: response}.as_json
    elsif data[:type] == 'past'
      yesterday_events  =  Event.where('Date(start_date) = ?',  Date.today - 1.day)
      yesterday_events  =  yesterday_events.page(page.to_i).per_page(per_page.to_i)
      paging_data       =  JsonBuilder.get_paging_data(page, per_page, yesterday_events)
      yesterday_events  =  yesterday_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: yesterday_events, paging_data: paging_data}.as_json
      resp_data       = {yesterday_events: response}.as_json
    end
    resp_status     = 1
    resp_message    = 'Event list'
    resp_errors     = ''
    resp_request_id = ''
    resp_request_id = data[:request_id] if data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.np_event_list(data)
    per_page = (data[:per_page] || @@limit).to_i
    page     = (data[:page] || 1).to_i
  
    if data[:type] == 'upcoming'
      a_day_after_events  = Event.where('Date(start_date) = ?',  Date.today + 1.day)
      a_day_after_events  =  a_day_after_events.page(page.to_i).per_page(per_page.to_i)
      paging_data         =  JsonBuilder.get_paging_data(page, per_page, a_day_after_events)
      a_day_after_events  =  a_day_after_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: a_day_after_events, paging_data: paging_data}.as_json
      resp_data       = {a_day_after_events: response}.as_json
    elsif data[:type] == 'past'
      a_day_before_events  = Event.where('Date(start_date) = ?',  Date.today - 2.day)
      a_day_before_events  =  a_day_before_events.page(page.to_i).per_page(per_page.to_i)
      paging_data          =  JsonBuilder.get_paging_data(page, per_page, a_day_before_events)
      a_day_before_events  =  a_day_before_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: a_day_before_events, paging_data: paging_data}.as_json
      resp_data       = {a_day_before_events: response}.as_json
    end
    resp_status     = 1
    resp_message    = 'Event list'
    resp_errors     = ''
    resp_request_id = ''
    resp_request_id = data[:request_id] if data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.week_event_list(data)
    per_page = (data[:per_page] || @@limit).to_i
    page     = (data[:page] || 1).to_i
  
    if data[:type] == 'upcoming'
      next_week_events  = Event.where('Date(start_date) > ? AND Date(start_date) <= ?', Date.today + 1.day, Date.today + 1.week)
      next_week_events  =  next_week_events.page(page.to_i).per_page(per_page.to_i)
      paging_data       =  JsonBuilder.get_paging_data(page, per_page, next_week_events)
      next_week_events  =  next_week_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: next_week_events, paging_data: paging_data}.as_json
      resp_data       = {next_week_events: response}.as_json
    elsif data[:type] == 'past'
      last_week_events  = Event.where('Date(start_date) >= ? AND Date(start_date) < ?', Date.today - 1.week, Date.today - 2.day)
      last_week_events  =  last_week_events.page(page.to_i).per_page(per_page.to_i)
      paging_data       =  JsonBuilder.get_paging_data(page, per_page, last_week_events)
      last_week_events  =  last_week_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: last_week_events, paging_data: paging_data}.as_json
      resp_data       = {last_week_events: response}.as_json
    end
    resp_status     = 1
    resp_message    = 'Event list'
    resp_errors     = ''
    resp_request_id = ''
    resp_request_id = data[:request_id] if data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.all_event_list(data)
    per_page = (data[:per_page] || @@limit).to_i
    page     = (data[:page] || 1).to_i
  
    if data[:type] == 'upcoming'
      upcoming_events  = Event.where('Date(start_date) > ?', Date.today + 1.week)
      upcoming_events  =  upcoming_events.page(page.to_i).per_page(per_page.to_i)
      paging_data      =  JsonBuilder.get_paging_data(page, per_page, upcoming_events)
      upcoming_events  =  upcoming_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: upcoming_events, paging_data: paging_data}.as_json
      resp_data       = {upcoming_events: response}.as_json
    elsif data[:type] == 'past'
      previous_events  = Event.where('Date(start_date) < ?', Date.today - 1.week)
      previous_events  =  previous_events.page(page.to_i).per_page(per_page.to_i)
      paging_data      =  JsonBuilder.get_paging_data(page, per_page, previous_events)
      previous_events  =  previous_events.as_json(
          only:[:id, :event_name, :event_details, :start_date, :end_date, :location],
          include:{
              event_attachments:{
                  only:[:id, :attachment_url, :thumbnail_url, :message, :attachment_type]
              }
          }
      )
      response        = {events: previous_events, paging_data: paging_data}.as_json
      resp_data       = {previous_events: response}.as_json
    end
    resp_status     = 1
    resp_message    = 'Event list'
    resp_errors     = ''
    resp_request_id = ''
    resp_request_id = data[:request_id] if data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end
end

# == Schema Information
#
# Table name: events
#
#  id                :integer          not null, primary key
#  name              :string
#  country_id        :integer
#  state_id          :integer
#  city_id           :integer
#  organization      :text
#  location          :text
#  description       :text
#  cost              :integer
#  currency_id       :integer
#  camp_website      :text
#  start_date        :datetime
#  end_date          :datetime
#  upload            :string
#  member_profile_id :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
