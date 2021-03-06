# == Schema Information
#
# Table name: users
#
#  id                     :integer          not null, primary key
#  email                  :string(255)      default(""), not null
#  encrypted_password     :string(255)      default(""), not null
#  reset_password_token   :string(255)
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0)
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string(255)
#  last_sign_in_ip        :string(255)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  name                   :string(255)
#  admin                  :boolean          default(FALSE), not null
#  projects_limit         :integer          default(10)
#  skype                  :string(255)      default(""), not null
#  linkedin               :string(255)      default(""), not null
#  twitter                :string(255)      default(""), not null
#  authentication_token   :string(255)
#  dark_scheme            :boolean          default(FALSE), not null
#  theme_id               :integer          default(1), not null
#  bio                    :string(255)
#  blocked                :boolean          default(FALSE), not null
#  failed_attempts        :integer          default(0)
#  locked_at              :datetime
#  extern_uid             :string(255)
#  provider               :string(255)
#  username               :string(255)
#

class User < ActiveRecord::Base
  devise :database_authenticatable, :token_authenticatable, :lockable,
         :recoverable, :rememberable, :trackable, :validatable, :omniauthable

  attr_accessible :email, :password, :password_confirmation, :remember_me, :bio, :name, :username,
                  :skype, :linkedin, :twitter, :dark_scheme, :theme_id, :force_random_password,
                  :extern_uid, :provider, as: [:default, :admin]
  attr_accessible :projects_limit, as: :admin

  attr_accessor :force_random_password

  # Namespace for personal projects
  has_one :namespace, class_name: "Namespace", foreign_key: :owner_id, conditions: 'type IS NULL', dependent: :destroy
  has_many :groups, class_name: "Group", foreign_key: :owner_id

  has_many :keys, dependent: :destroy
  has_many :users_projects, dependent: :destroy
  has_many :issues, foreign_key: :author_id, dependent: :destroy
  has_many :notes, foreign_key: :author_id, dependent: :destroy
  has_many :merge_requests, foreign_key: :author_id, dependent: :destroy
  has_many :events, class_name: "Event", foreign_key: :author_id, dependent: :destroy
  has_many :recent_events, class_name: "Event", foreign_key: :author_id, order: "id DESC"
  has_many :assigned_issues, class_name: "Issue", foreign_key: :assignee_id, dependent: :destroy
  has_many :assigned_merge_requests, class_name: "MergeRequest", foreign_key: :assignee_id, dependent: :destroy

  validates :name, presence: true
  validates :bio, length: { within: 0..255 }
  validates :extern_uid, allow_blank: true, uniqueness: {scope: :provider}
  validates :projects_limit, presence: true, numericality: {greater_than_or_equal_to: 0}
  validates :username, presence: true, uniqueness: true,
            format: { with: Gitlab::Regex.username_regex,
                      message: "only letters, digits & '_' '-' '.' allowed. Letter should be first" }


  before_validation :generate_password, on: :create
  before_save :ensure_authentication_token
  alias_attribute :private_token, :authentication_token

  delegate :path, to: :namespace, allow_nil: true, prefix: true

  # Scopes
  scope :admins, where(admin:  true)
  scope :blocked, where(blocked:  true)
  scope :active, where(blocked:  false)
  scope :alphabetically, order('name ASC')

  #
  # Class methods
  #
  class << self
    def filter filter_name
      case filter_name
      when "admins"; self.admins
      when "blocked"; self.blocked
      when "wop"; self.without_projects
      else
        self.active
      end
    end

    def not_in_project(project)
      if project.users.present?
        where("id not in (:ids)", ids: project.users.map(&:id) )
      else
        scoped
      end
    end

    def without_projects
      where('id NOT IN (SELECT DISTINCT(user_id) FROM users_projects)')
    end

    def create_from_omniauth(auth, ldap = false)
      gitlab_auth.create_from_omniauth(auth, ldap)
    end

    def find_or_new_for_omniauth(auth)
      gitlab_auth.find_or_new_for_omniauth(auth)
    end

    def find_for_ldap_auth(auth, signed_in_resource = nil)
      gitlab_auth.find_for_ldap_auth(auth, signed_in_resource)
    end

    def gitlab_auth
      Gitlab::Auth.new
    end

    def search query
      where("name LIKE :query or email LIKE :query", query: "%#{query}%")
    end
  end

  #
  # Instance methods
  #
  def generate_password
    if self.force_random_password
      self.password = self.password_confirmation = Devise.friendly_token.first(8)
    end
  end


  # Namespaces user has access to
  def namespaces
    namespaces = []

    # Add user account namespace
    namespaces << self.namespace if self.namespace

    # Add groups you can manage
    namespaces += if admin
                    Group.all
                  else
                    groups.all
                  end
    namespaces
  end

  # Groups where user is an owner
  def owned_groups
    groups
  end

  # Groups user has access to
  def authorized_groups
    @authorized_groups ||= begin
                           groups = Group.where(id: self.authorized_projects.pluck(:namespace_id)).all
                           groups = groups + self.groups
                           groups.uniq
                         end
  end


  # Projects user has access to
  def authorized_projects
    project_ids = users_projects.pluck(:project_id)
    project_ids = project_ids | owned_projects.pluck(:id)
    Project.where(id: project_ids)
  end

  # Projects in user namespace
  def personal_projects
    Project.personal(self)
  end

  # Projects where user is an owner
  def owned_projects
    Project.where("(projects.namespace_id IN (:namespaces)) OR
                  (projects.namespace_id IS NULL AND projects.creator_id = :user_id)",
                  namespaces: namespaces.map(&:id), user_id: self.id)
  end

  # Team membership in personal projects
  def tm_in_personal_projects
    personal_projects.users_projects.where(user_id: self.id)
  end

  # Returns a string for use as a Gitolite user identifier
  #
  # Note that Gitolite 2.x requires the following pattern for users:
  #
  #   ^@?[0-9a-zA-Z][0-9a-zA-Z._\@+-]*$
  def identifier
    # Replace non-word chars with underscores, then make sure it starts with
    # valid chars
    email.gsub(/\W/, '_').gsub(/\A([\W\_])+/, '')
  end

  def is_admin?
    admin
  end

  def require_ssh_key?
    keys.count == 0
  end

  def can_create_project?
    projects_limit > personal_projects.count
  end

  def can_create_group?
    is_admin?
  end

  def abilities
    @abilities ||= begin
                     abilities = Six.new
                     abilities << Ability
                     abilities
                   end
  end

  def can? action, subject
    abilities.allowed?(self, action, subject)
  end

  def last_activity_project
    projects.first
  end

  def first_name
    name.split.first unless name.blank?
  end

  def cared_merge_requests
    MergeRequest.where("author_id = :id or assignee_id = :id", id: self.id)
  end

  # Remove user from all projects and
  # set blocked attribute to true
  def block
    users_projects.find_each do |membership|
      return false unless membership.destroy
    end

    self.blocked = true
    save
  end

  def projects_limit_percent
    return 100 if projects_limit.zero?
    (personal_projects.count.to_f / projects_limit) * 100
  end

  def recent_push project_id = nil
    # Get push events not earlier than 2 hours ago
    events = recent_events.code_push.where("created_at > ?", Time.now - 2.hours)
    events = events.where(project_id: project_id) if project_id

    # Take only latest one
    events = events.recent.limit(1).first
  end

  def projects_sorted_by_activity
    authorized_projects.sorted_by_activity
  end

  def several_namespaces?
    namespaces.size > 1
  end

  def namespace_id
    namespace.try :id
  end
end
