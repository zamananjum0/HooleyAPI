class Api::V1::UsersController < Api::V1::ApiProtectedController
  
  # calling from web
  def index
    member_profiles =  MemberProfile.all
    member_profiles =  member_profiles.page(params[:page].to_i).per_page(params[:per_page].to_i)
    paging_data     = get_paging_data(params[:page], params[:per_page], member_profiles)
    member_profiles =  member_profiles.as_json(
        only: [:id, :photo, :country_id, :city_id, :is_profile_public, :default_group_id, :dob, :account_type, :is_age_visible, :gender, :current_city, :home_town, :employer, :college, :high_school, :organization, :hobbies,:contact_email, :contact_phone, :contact_website, :contact_address],
        methods: [:posts_count, :followings_count, :followers_count, :events_count],
        include: {
            user: {
                only: [:id, :profile_id, :profile_type, :first_name, :email, :last_name, :phone]
            },
            profile_interests:{
                only:[:id, :name, :interest_type, :photo_url]
            },
            country: {
                only: [:id, :country_name]
            },
            city:{
                only:[:id, :name]
            },
            occupation:{
                only:[:id, :name]
            },
            college_major:{
                only:[:id, :name]
            },
            relationship_status:{
                only:[:id, :name]
            },
            political_view:{
                only:[:id, :name]
            },
            religion:{
                only:[:id, :name]
            },
            language:{
                only:[:id, :name]
            },
            ethnic_background:{
                only:[:id, :name]
            }
        }
    )
    resp_data    = {member_profiles: member_profiles}.as_json
    resp_status  = 1
    resp_message = 'Success'
    resp_errors  = ''
    common_api_response(resp_data, resp_status, resp_message, resp_errors, paging_data)
  end
  
  def user_events
    member_profile = MemberProfile.find_by_id(params[:member_profile_id])
    if member_profile.present?
      events       =  member_profile.events
      events       =  events.page(params[:page].to_i).per_page(params[:per_page].to_i)
      paging_data  =  get_paging_data(params[:page], params[:per_page], events)
      resp_data    =  Event.events_response(events)
      resp_status  = 1
      resp_message = 'Success'
      resp_errors  = ''
    else
      paging_data  = ''
      resp_data    = {}
      resp_status  = 0
      resp_message = 'error'
      resp_errors  = 'User not found'
    end
    common_api_response(resp_data, resp_status, resp_message, resp_errors, paging_data)
  end
  
  def user_posts
    member_profile = MemberProfile.find_by_id(params[:member_profile_id])
    if member_profile.present?
      posts        =  member_profile.posts
      posts        =  posts.page(params[:page].to_i).per_page(params[:per_page].to_i)
      paging_data  =  get_paging_data(params[:page], params[:per_page], posts)
      resp_data    =  Post.posts_array_response(posts, member_profile)
      resp_status  = 1
      resp_message = 'Success'
      resp_errors  = ''
    else
      paging_data  = ''
      resp_data    = {}
      resp_status  = 0
      resp_message = 'error'
      resp_errors  = 'User not found'
    end
    common_api_response(resp_data, resp_status, resp_message, resp_errors, paging_data)
  end
  
  def user_followers
    member_profile = MemberProfile.find_by_id(params[:member_profile_id])
    if member_profile.present?
      member_followers =  MemberFollowing.where(following_profile_id: member_profile.id)
      member_followers =  member_followers.page(params[:page].to_i).per_page(params[:per_page].to_i)
      paging_data      =  get_paging_data(params[:page], params[:per_page], member_followers)
      member_followers =  member_followers.as_json(
         only: [:id, :following_status],
         include:{
             member_profile:{
                 only:[:id],
                 include:{
                     user:{
                         only:[:id, :email, :first_name, :last_name]
                     }
                 }
             }
         }
      )
      resp_data    =  {member_followers: member_followers}.as_json
      resp_status  = 1
      resp_message = 'Success'
      resp_errors  = ''
    else
      paging_data  = ''
      resp_data    = {}
      resp_status  = 0
      resp_message = 'error'
      resp_errors  = 'User not found'
    end
    common_api_response(resp_data, resp_status, resp_message, resp_errors, paging_data)
  end
end
