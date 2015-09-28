class Scenario < ActiveRecord::Base
  include Aws
  include Provider
  attr_accessor :template # For picking a template when creating a new scenario
  
  belongs_to :user
  has_many :clouds, dependent: :destroy
  has_many :questions, dependent: :destroy
  has_many :roles, dependent: :destroy
  has_many :recipes, dependent: :destroy
  has_many :groups, dependent: :destroy
  has_many :subnets, through: :clouds
  has_many :instances, through: :subnets

  validate :validate_name, :validate_stopped
  before_destroy :validate_stopped, prepend: true
  # upon the destruction of a scenario, create an
  # entry in the statistic table.
  before_destroy :create_statistic, prepend: true
  # after creating statistic, destory the s3 buckets where the bash histories were cached
  before_destroy :destroy_s3_bash_histories

  def validate_name
    self.name = self.name.strip
    if self.name == ""
      errors.add(:name, "Can not be blank")
      return false
    elsif /\W/.match(self.name)
      errors.add(:name, "Name can only contain alphanumeric and underscore")
      return false
    elsif /^_*_$/.match(self.name)
      errors.add(:name, "Name not allowed")
      return false
    end
    true
  end

  def validate_stopped
    if not self.stopped?
      errors.add(:running, "can only modify scenario if it is stopped")
      return false
    end
    true
  end

  def bootable?
    return (self.stopped? or self.partially_booted?) 
  end

  def unbootable?
    return (self.partially_booted? or self.booted? or self.boot_failed? or self.unboot_failed? or self.paused?)
  end

  def path
    local = "#{Settings.app_path}scenarios/local/#{self.name.downcase}"
    return local if File.exists? local
    return "#{Settings.app_path}scenarios/user/#{self.user.id}/#{self.name.downcase}"
  end

  def yml_path
    "#{self.path}/#{self.name.downcase}.yml"
  end

  def change_name(name)
    if not self.stopped?
      errors.add(:running, "can not modify while scenario is not stopped");
      return false
    end

    name = name.strip
    if name == ""
      errors.add(:name, "Can not be blank")
    elsif /\W/.match(name)
      errors.add(:name, "Name can only contain alphanumeric and underscore")
    elsif /^_*_$/.match(name)
      errors.add(:name, "Name not allowed")
    elsif not self.custom?
      errors.add(:custom, "Scenario must be custom to change name")
    elsif not self.stopped?
      errors.add(:running, "Scenario must be stopped before name can be changed")
    elsif File.exists? "#{Settings.app_path}scenarios/local/#{name.downcase}/#{name.downcase}.yml"
      errors.add(:name, "Name taken")
    elsif File.exists? "#{Settings.app_path}scenarios/user/#{self.user.id}/#{name.downcase}/#{name.downcase}.yml"
      errors.add(:name, "Name taken")
    else
      oldpath = "#{Settings.app_path}scenarios/user/#{self.user.id}/#{self.name.downcase}"
      newpath = "#{Settings.app_path}scenarios/user/#{self.user.id}/#{name.downcase}"
      FileUtils.cp_r oldpath, newpath
      FileUtils.mv "#{newpath}/#{self.name.downcase}.yml", "#{newpath}/#{name.downcase}.yml"
      FileUtils.rm_r oldpath
      self.name = name
      self.save
      self.update_yml
      true
    end
    false
  end

  def owner?(id)
    return self.user_id == id
  end

  def debug(message)
    log = self.log ? self.log : ''
    message = '' if !message
    self.update_attribute(:log, log + message + "\n")
  end

  def scenario
    return self
  end

  def players
    players = []
    self.clouds.each do |cloud|
      cloud.subnets.each do |subnet|
        subnet.instances.each do |instance|
          instance.instance_groups.each do |instance_group|
            instance_group.group.players.each do |player|
              found = false
              players.each do |inplayer|
                if inplayer.login == player.login
                  found = true
                end
              end
              if !found
                players.push(player)
              end
            end
          end
        end
      end
    end
    return players
  end

  def public_instances_reachable?
    reachable
    return self.instances.select{ |i| not i.port_open?(22) }.any?
  end

  def instances_initialized?
    return self.instances.select{ |i| not i.initialized? }.any?
  end

  def clouds_booting?
    return self.clouds.select{ |c| (c.booting? or c.queued_boot?) }.any?
  end

  def clouds_unbooting?
    return self.clouds.select{ |c| c.unbooting? or c.queued_unboot? }.any?
  end

  def subnets_booting?
    return self.subnets.select{ |s| (s.booting? or s.queued_boot?) }.any?
  end

  def subnets_unbooting?
    return self.subnets.select{ |s| s.unbooting? or s.queued_unboot? }.any?
  end

  def clouds_boot_failed?
    return self.clouds.select{ |c| c.boot_failed? }.any?
  end

  def clouds_unboot_failed?
    return self.clouds.select{ |c| c.unboot_failed? }.any?
  end

  def clouds_booted?
    return self.clouds.select{ |c| c.booted?  }.any?
  end

  def check_status
    cnt = 0
    stopped = 0
    queued_boot = 0
    queued_unboot = 0
    booted = 0
    booting = 0
    unbooting = 0
    boot_failed = 0
    unboot_failed = 0
    paused = 0
    pausing  = 0
    starting = 0

    self.clouds.each do |cloud|
      cnt += 1
      stopped += 1 if cloud.stopped?
      queued_boot += 1 if cloud.queued_boot?
      queued_unboot += 1 if cloud.queued_unboot?
      booted += 1 if cloud.booted?
      booting += 1 if cloud.booting?
      unbooting += 1 if cloud.unbooting?
      boot_failed += 1 if cloud.boot_failed?
      unboot_failed += 1 if cloud.unboot_failed?

      cloud.subnets.each do |subnet|
        cnt += 1
        stopped += 1 if subnet.stopped?
        queued_boot += 1 if subnet.queued_boot?
        queued_unboot += 1 if subnet.queued_unboot?
        booted += 1 if subnet.booted?
        booting += 1 if subnet.booting?
        unbooting += 1 if subnet.unbooting?
        boot_failed += 1 if subnet.boot_failed?
        unboot_failed += 1 if subnet.unboot_failed?

        subnet.instances.each do |instance|
          cnt += 1
          stopped += 1 if instance.stopped?
          queued_boot += 1 if instance.queued_boot?
          queued_unboot += 1 if instance.queued_unboot?
          booted += 1 if instance.booted?
          paused += 1 if instance.paused?
          pausing += 1 if instance.pausing?
          starting += 1 if instance.starting?
          booting += 1 if instance.booting?
          unbooting += 1 if instance.unbooting?
          boot_failed += 1 if instance.boot_failed?
          unboot_failed += 1 if instance.unboot_failed?
        end
      end
    end

    if boot_failed > 0
      self.set_boot_failed
    elsif unboot_failed > 0
      self.set_unboot_failed
    elsif booting > 0
      self.set_booting
    elsif unbooting > 0
      self.set_unbooting
    elsif queued_boot > 0
      self.set_queued_boot
    elsif queued_unboot > 0
      self.set_queued_unboot
    elsif paused > 0
      self.set_paused
    elsif pausing > 0
      self.set_pausing
    elsif starting > 0
      self.set_starting
    elsif booted > 0
      if booted == cnt
        self.set_booted
      else
        self.set_partially_booted
      end
    else
      self.set_stopped
    end
  end

  def get_global_recipes_and_descriptions
    recipes = { }
    Dir.foreach("#{Settings.app_path}/scenarios/recipes") do |file|
      next if file == '.' or file == '..'

      recipe = file.gsub(".rb.erb", "")
      description = ''
      description_file = "#{Settings.app_path}/scenarios/recipes/descriptions/#{recipe}"
      if File.exists? description_file
        description += File.open(description_file).read
      end
      recipes[recipe] = description 
    end
    recipes
  end

  def clone(name)
    clone = Scenario.new(name: name.strip, custom: true, user_id: self.user_id)

    # validate name
    if clone.name == ""
      clone.errors.add(:name, "Can not be blank")
      return clone
    elsif /\W/.match(clone.name)
      clone.errors.add(:name, "Name can only contain alphanumeric and underscore")
      return clone
    elsif /^_*_$/.match(clone.name)
      clone.errors.add(:name, "Name not allowed")
      return clone
    elsif File.exists?("#{Settings.app_path}scenarios/local/#{clone.name.downcase}") or (clone.name.downcase == self.name.downcase)
      clone.errors.add(:name, "Name taken")
      return clone
    end

    # make user directory
    userdir = "#{Settings.app_path}/scenarios/user/#{self.user.id}"
    Dir.mkdir userdir unless File.exists? userdir

    # make clone directory
    Dir.mkdir clone.path

    # make recipe directory and copy every recipe
    Dir.mkdir "#{clone.path}/recipes"
    Dir.foreach("#{self.path}/recipes") do |recipe|
      next if recipe == '.' or recipe == '..'
      FileUtils.cp "#{self.path}/recipes/#{recipe}", "#{clone.path}/recipes"
    end

    # Copy yml file and replace Name:
    newyml = File.open(clone.yml_path, "w")
    File.open(self.yml_path).each do |line|
      if /\s*Name:\s*#{self.name}/.match(line)
        line = line.gsub("#{self.name}", clone.name)
      end
      newyml.write line
    end
    newyml.close

    # create and return cloned scenario
    return YmlRecord.load_yml(clone.name, self.user)
  end

  def make_custom
    self.name = self.name.strip
    if self.name == ""
      errors.add(:name, "Can not be blank")
      return false
    elsif /\W/.match(self.name)
      errors.add(:name, "Name can only contain alphanumeric and underscore")
      return false
    elsif /^_*_$/.match(self.name)
      errors.add(:name, "Name not allowed")
      return false
    end

    if File.exists? "#{Settings.app_path}/scenarios/local/#{self.name.downcase}"
      errors.add(:name, "A global scenario with that name already exists")
      return false
    end

    if File.exists? "#{Settings.app_path}/scenarios/user/#{self.user.id}/#{self.name.downcase}"
      errors.add(:name, "A custom scenario with that name already exists")
      return false
    end

    FileUtils.mkdir self.path
    FileUtils.mkdir "#{self.path}/recipes"
    self.update_attribute(:modified, true)
    self.update_yml

    return true
  end

  def update_yml
    if not self.custom?
      self.errors.add(:customizable, "Scenario is not customizable")
      return false
    end
    if not self.modified?
      self.errors.add(:modified, "Scenario is not modified")
      return false
    end

    yml = { 
      "Name" => self.name, 
      "Description" => self.description,
      "Instructions" => self.instructions,
      "Groups" => nil,
      "Clouds" => nil,
      "Subnets" => nil,
      "Instances" => nil
    }

    yml["Roles"] = self.roles.empty? ? nil : self.roles.map { |r|
      { "Name"=>r.name, 
        "Packages" => r.packages.empty? ? nil : r.packages, 
        "Recipes"=>r.recipes.empty? ? nil : r.recipes.map { |rec| rec.name }
      }
    }

    yml["Groups"] = self.groups.empty? ? nil : self.groups.map { |group| 
      { "Name" => group.name, 
        "Access" => { 
          "Administrator" => group.instance_groups.select{ |ig| ig.administrator  }.map{ |ig| ig.instance.name },
          "User" => group.instance_groups.select{ |ig| not ig.administrator  }.map{ |ig| ig.instance.name }
        },
        "Users" => group.players.empty? ? nil : group.players.map { |p| { "Login" => p.login, "Password" => p.password, "Id" => p.user_id } }
      }
    }

    yml["Clouds"] = self.clouds.empty? ? nil : self.clouds.map { |cloud|
      { "Name" => cloud.name, "CIDR_Block" => cloud.cidr_block}
    }

    yml["Subnets"] = self.subnets.empty? ? nil : self.subnets.map { |subnet| {
        "Name" => subnet.name, 
        "Cloud" => subnet.cloud.name, 
        "CIDR_Block" => subnet.cidr_block, 
        "Internet_Accessible" => subnet.internet_accessible
      }
    }

    yml["Instances"] = self.instances.empty? ? nil : self.instances.map { |instance| {
        "Name" => instance.name, 
        "Subnet" => instance.subnet.name,
        "OS" => instance.os,
        "IP_Address" => instance.ip_address, 
        "Internet_Accessible" => instance.internet_accessible,
        "Roles" => instance.roles.map { |r| r.name }
      }
    }

    f = File.open("#{self.path}/#{self.name.downcase}.yml", "w")
    f.write(yml.to_yaml)
    f.close()
    self.update_attribute(:modified, false)
  end

  private
    # methods for creating statistics on scenarios
    def create_statistic
      # private method to initialize a statistic entry
      # during Scenario destriction time. These are the first
      # steps of the analytics pipeline.

      statistic = Statistic.new
      # populate statistic with bash histories
      self.instances.all.each do |instance|
        # concatenate all bash histories into one big string
        statistic.bash_histories += instance.get_bash_history
        puts instance.get_bash_history  # for debugging
      end
  
      # partition the big bash history string into a nested hash structure
      # mapping usernames to the commands they entered.
      statistic.bash_analytics = partition_bash(statistic.bash_histories.split("\n"))
      puts statistic.bash_analytics

      # and with scenario metadata
      statistic.user_id = self.user_id
      statistic.scenario_name = self.name
      statistic.scenario_created_at = self.created_at
      # we'll also want to grab a list of users from the scenario,
      # otherwise this data can be got, from the keys of
      # the bash analytics field
      statistic.save  # stuff into db

      # create statistic file for download
      bash_analytics = ""
      statistic.bash_analytics.each do |analytic| 
        bash_analytics = bash_analytics + "#{analytic}" + "\n"
      end
      file_text = "Scenario #{statistic.scenario_name} created at #{statistic.scenario_created_at}\nStatistic #{statistic.id} created at #{statistic.created_at}\n\nBash Histories: \n \n#{statistic.bash_histories} \nBash Analytics: \n#{bash_analytics}"
      File.write("#{Rails.root}/public/statistics/#{statistic.id}_Statistic_#{statistic.scenario_name}.txt",file_text)
    end


    # depreciated code: analytics portion of the code
    # now lives with the statistic model. Beyond that,
    # we can now delete statistics without any trouble
    def bash_analytics(bash_history)
      # simply count frequencies of options and commands used during a session
      options_frequencies = Hash.new(0)
      bash_history = bash_history.split("\n")
      bash_history.each do |command|
        # count the occurances w/a simple regexp
        options = command.scan(/[-'[A-Za-z]]+/);
        options.each do |option|
          options_frequencies[option] += 1;
        end
      end
      # sort by number of times an command/option has been used
      options_frequencies.sort_by { |option| option[1] }
      return options_frequencies
    end

    def partition_bash(data)
      # input -> data: a list of strings of bash commands split by newline
      # output -> d: a hash {user->{timestamp->command}}

      # method to populate the bash_analytics field of
      # a Statistic model with a nested hash
      # that maps users to timestamps to commands
      d = Hash.new(0)  # {user -> { timestamp -> command }}
      i = 4  # our index, begin @ index four to skip unneeded lines
      # make two passes over the data
      #   first, creating the users list
      #   & then, grabbing commands associated
      #     with each of those users    
      
     

      # outer hash
      while i < data.length
        if data[i][0..1] == "##"
          e = data[i].length  # endpoint
          u = data[i][3..e-1]  # username
          if !d.include?(u)
            # don't overwrite unless already included
            d[u] = Hash.new(0)
          end
        end
        i += 1
      end
      i = 0  # reset index
      users = d.keys  # users
      u_i = 0 # user index

      # inner hash
      while i < data.length
        if data[i][0..1] == "# "
          e = data[i].length
          t = data[i][2..e-1]  # timestamp
          if data[i + 1] != ""
            c = data[i + 1]  # command
            d[users[u_i]][t] = [c, 0]
            i += 1  # inc twice
          end
        elsif data[i][0..1] == "##"
          e = data[i].length
          u = data[i][3..e-1]  # to find index in users
          u_i = users.find_index(u)  # & change user u
        end
        i += 1
      end
      return d  # {users => { timestamps => commands }}
    end

    def destroy_s3_bash_histories
      # bash histories are persistent between boot cycles
      # only once scenario is destroyed are they deleted from s3 bucket
      self.instances.each do |instance|
        instance.aws_instance_delete_bash_history_page
      end
    end  
  end  # end private methods       
# end