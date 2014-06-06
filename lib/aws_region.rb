require 'aws-sdk-core'
require 'yaml'
require 'json'

class AwsBase
  def log(msg)
    @logger.write("#{Time.now.strftime("%b %D, %Y %H:%S:%M:")} #{msg}\n") if @logger
  end
end

# AwsRegion is a simplified wrapper on top of a few of the Aws core objects
# The main goal is to expose a extremely simple interface for some our most
# frequently used Aws facilities.
class AwsRegion < AwsBase
  attr_accessor :ec2, :region, :rds, :account_id, :elb, :cw, :s3, :sns  
  REGIONS = {'or' => "us-west-2", 'ca' => "us-west-1", 'va' => 'us-east-1'}

  # @param region [String] must be one of the keys of the {AwsRegion::REGIONS REGIONS} static hash
  # @param account_id [String] Aws account id
  # @param access_key_id [String] Aws access key id
  # @param secret_access_key [String] Aws secret access key
  def initialize(region, account_id, access_key_id, secret_access_key, logger = nil)
    @logger = logger
    @region = REGIONS[region]
    @account_id = account_id
    Aws.config = {:access_key_id => access_key_id,
                  :secret_access_key => secret_access_key}
    @ec2 = Aws::EC2.new({:region => @region})
    @rds = Aws::RDS.new({:region => @region})
    @elb = Aws::ElasticLoadBalancing.new({:region => @region})
    @cw = Aws::CloudWatch.new({:region => @region})
    @s3 = Aws::S3.new({:region => @region})
    @sns = Aws::SNS.new({:region => @region})
  end

  # Simple EC2 Instance finder.  Can find using instance_id, or using
  # :environment and :purpose instance tags which must both match.
  #
  # @param options [Hash] containing search criteria.  Values can be:
  #   * :instance_id - identifies an exact instance
  #   * :environment - instance tag
  #   * :purpose     - instance tag
  # @return [Array<AwsInstance>] instances found to match criteria
  def find_instances(options={})
    instances = []
    @ec2.describe_instances[:reservations].each do |i|
      i.instances.each do |y|
        instance = AwsInstance.new(self, {:instance => y})
        if instance.state != 'terminated'
          if options.has_key?(:environment) and options.has_key?(:purpose)
            instances << instance if  instance.tags[:environment] == options[:environment] and instance.tags[:purpose] == options[:purpose]
          elsif options.has_key?(:instance_id)
            instances << instance if instance.id == options[:instance_id]
          end
        end
      end
    end
    return instances
  end

  # Simple DB Instance finder.  Can find using instance_id, or using
  # :environment and :purpose instance tags which must both match.
  #
  # @param options [Hash] containing search criteria.  Values can be:
  #   * :instance_id - identifies an exact instance
  #   * :environment - instance tag
  #   * :purpose     - instance tag
  # @return [Array<AwsDbInstance>] instances found to match criteria
  def find_db_instances(options={})
    instances = []
    @rds.describe_db_instances[:db_instances].each do |i|
      instance = AwsDbInstance.new(self, {:instance => i})
      if options.has_key?(:instance_id)
        instance.id == options[:instance_id]
        instances << instance
      elsif instance.tags[:environment] == options[:environment] and
          instance.tags[:purpose] == options[:purpose]
        instances << instance
      end
    end
    instances
  end


  # Search region for a bucket by name
  #
  # @param options [Hash] containing search criteria.  Values can be:
  #   * :bucket  -  Bucket name
  # @return [Array<AwsBucket>] instances found to match criteria
  def find_buckets(options={})
    buckets = []
    _buckets = @s3.list_buckets()
    _buckets[:buckets].each do |b|
      buckets << AwsBucket.new(self, {id: b[:name]}) if b[:name] == options[:bucket]
    end
    buckets
  end

  # Construct new EC2 instance
  #
  # @param options [Hash] containing initialization parameters.  See {AwsInstance#initialize}
  # @return [AwsInstance]
  def create_instance(options={})
    AwsInstance.new(self, options)
  end

  # Construct new DB instance
  #
  # @param options [Hash] containing initialization parameters.  See {AwsDbInstance#initialize}
  # @return [AwsDbInstance]
  def create_db_instance(options={})
    AwsDbInstance.new(self, options)
  end

  # Construct new CloudWatch instance
  #
  # @param options [Hash] containing initialization parameters.  See {AwsCw#initialize}
  # @return [AwsCw]
  def create_cw_instance(options={})
    AwsCw.new(self, options)
  end

  # Construct new AwsBucket instance
  #
  # @param options [Hash] containing initialization parameters.  See {AwsBucket#initialize}
  # @return [AwsBucket]
  def create_bucket(options={})
    AwsBucket.new(self, options)
  end

  def create_sns_instance
    AwsSns.new(self)
  end

  class AwsSns
    attr_accessor :region
    def initialize(region)
      @region = region
    end
    def publish(topic_arn, subject) #, message)
      @region.sns.publish(topic_arn: topic_arn, message: "unused for texts", subject: subject)
    end
  end

# Methods for dealing with CloudWatch
  class AwsCw  < AwsBase
    attr_accessor :region

    # @param region [String] - Value from REGION static hash
    def initialize(region, options={})
      @region = region
    end

    # Put a cw metric
    # @param arg_csv [String] - CSV row: "namespace,name,value,dims"
    # * Note that dims is formatted as an arbitrary semicolon separated list of name:value dimensions.  For example:
    #   * "activeservers,count,10,env:prod;purp:test"
    # @return [Aws::PageableResponse]
    def put_metric(arg_csv)
      (namespace, name, value, dims) = arg_csv.split(",")
      dimensions = []
      dims.split(";").each do |d|
        (n, v) = d.split(":")
        dimensions << {:name => n, :value => v}
      end
      args = {:namespace => namespace}
      metric ={:metric_name => name, :value => value.to_f, :timestamp => Time.now, :dimensions => dimensions}
      args[:metric_data] = [metric]
      @region.cw.put_metric_data(args)
    end
  end

  # Methods for dealing with S3 buckets
  class AwsBucket  < AwsBase
    attr_accessor :region

    # Constructs a bucket instance from an existing bucket, or creates a new one with the name
    # @param region [String]  - Value from REGION static hash
    # @param options [Hash] - Possible values:
    # * :id - id of existing bucket
    # * :bucket - Name of bucket to find or create
    def initialize(region, options={})
      @region = region
      if options.has_key?(:id)
        @id = options[:id]
      elsif options.has_key?(:bucket)
        bucket = options[:bucket]
        if @region.find_buckets({bucket: bucket}).length <= 0
          @region.s3.create_bucket({:bucket => bucket,
                                    :create_bucket_configuration => {:location_constraint => @region.region}})
          if @region.find_buckets({bucket: bucket}).length <= 0
            raise "Error creating bucket: #{bucket} in region: #{@region.region}"
          end
        end
        @id = bucket
      end
    end

    # Delete this bucket instance
    # @return [AwsPageableResponse]]
    def delete
      @region.s3.delete_bucket({bucket: @id})
    end

    # Put a local file to this bucket
    # @param filename [String]  - local file name
    # @param file_identity [String] - S3 file path
    # @return [AwsPageableResponse]
    def put_file(filename, file_identity)
      File.open(filename, 'r') do |reading_file|
        resp = @region.s3.put_object(
            acl: "bucket-owner-full-control",
            body: reading_file,
            bucket: @id,
            key: file_identity
        )
      end
    end

    # puts a local file to an s3 object in bucket on path
    # example: put_local_file(:bucket=>"bucket", :local_file_path=>"/tmp/bar/foo.txt", :aws_path=>"b")
    # would make an s3 object named foo.txt in bucket/b
    # @param local_file_path [String] - Location of file to put
    # @param aws_path [String] - S3 path to put the file
    # @param options [Hash] - Can contain any valid S3 bucket options see [docs](http://docs.aws.amazon.com/sdkforruby/api/frames.html)
    def put(local_file_path, aws_path, options={})
      aws_path = aws_path[0..-2] if aws_path[-1..-1] == '/'
      s3_path = "#{aws_path}/#{File.basename(local_file_path)}"
      log "s3 writing #{local_file_path} to bucket #{@id} path: #{aws_path} s3 path: #{s3_path}"
      f = File.open local_file_path, 'rb'
      options[:bucket] = @id
      options[:key] = s3_path
      options[:body] = f
      options[:storage_class] = 'REDUCED_REDUNDANCY'
      result = @region.s3.put_object(params=options)
      f.close
      result
    end

    # prefix is something like: hchd-A-A-Items
    # This will return in an array of strings the names of all objects in s3 in
    # the :aws_path under :bucket starting with passed-in prefix
    # example: :aws_path=>'development', :prefix=>'broadhead'
    #           would return array of names of objects in said bucket
    #           matching (in regex terms) development/broadhead.*
    # @param options [Hash] - Can contain:
    # * :aws_path - first part of S3 path to search
    # * :prefix - Actually suffix of path to search.
    # @return [Array<Hash>] - 0 or more objects
    def find(options={})
      aws_path = options[:aws_path]
      prefix = options[:prefix]
      aws_path = '' if aws_path.nil?
      aws_path = aws_path[0..-2] if aws_path[-1..-1] == '/'
      log "s3 searching bucket:#{@id} for #{aws_path}/#{prefix}"
      objects = @region.s3.list_objects(:bucket => @id,
                                        :prefix => "#{aws_path}/#{prefix}")
      f = objects.contents.collect(&:key)
      log "s3 searched  got: #{f.inspect}"
      f
    end

    # writes contents of S3 object to local file
    # example: 
    #          get( :s3_path_to_object=>'development/myfile.txt',
    #               :dest_file_path=>'/tmp/foo.txt')
    #          would write to local /tmp/foo.txt a file retrieved from s3
    #          at development/myfile.txt
    #
    #          get( :s3_path_to_object=>'development/myfile.txt' ) do |chunk|
    #            io.write chunk
    #          end
    # @param options [Hash] - Can contain:
    # * :s3_path_to_object - S3 object path
    # * :dest_file_path - local file were file will be written (ignored if block given)
    # @return [Boolean]
    def get(options={})
      begin
        s3_path_to_object = options[:s3_path_to_object]
        dest_file_path = options[:dest_file_path]
        File.delete dest_file_path if File.exists?(dest_file_path)
        log "s3 get bucket:#{@id} path:#{s3_path_to_object} dest:#{dest_file_path}"
        response = @region.s3.get_object(:bucket => @id,
                                         :key => s3_path_to_object)
        response.body.rewind

        if block_given?
          response.body.each { |chunk| yield chunk }
        else
          File.open(dest_file_path, 'wb') do |file|
            response.body.each { |chunk| file.write chunk }
          end
        end
      rescue Exception => e
        return false
      end
      true
    end

    # deletes from s3 an object at :s3_path_to_object
    # @param options [Hash] - Can be:
    # * :s3_path_to_object
    # @return [Boolean]
    def delete_object(options={})
      begin
        s3_path_to_object = options[:s3_path_to_object]
        log "s3 delete  #{s3_path_to_object}"
        @region.s3.delete_object(:bucket => @id,
                                 :key => s3_path_to_object)
      rescue Exception => e
        return false
      end
      true
    end

    # delete all objects in a bucket
    # @return [Boolean]
    def delete_all_objects
      begin
        response = @region.s3.list_objects({:bucket => @id})
        response[:contents].each do |obj|
          @region.s3.delete_object(:bucket => @id,
                                   :key => obj[:key])
        end
      rescue Exception => e
        return false
      end
      true
    end
  end

  # Class to handle RDS Db instances
  class AwsDbInstance  < AwsBase
    attr_accessor :id, :tags, :region, :endpoint

    # Creates an AwsDbInstance for an existing instance or creates a new database
    # @param region [String] - - Value from REGION static hash
    # @param options [Hash] - Can contain:
    # * :instance - If specified, create an instance of this class using this RDS instance.
    # * :opts - [Hash] - Includes parameters for constructing the database.  The format is:
    #   * :db_instance_identifier - RDS instance identifier
    #   * :db_subnet_group_name - DB Subgroup name
    #   * :publicly_accessible - [true|false]
    #   * :db_instance_class - RDS db instance class
    #   * :availability_zone - RDS/Aws availability zone
    #   * :multi_az - [true|false]
    #   * :engine - RDS engine (Only tested with Mysql at this point)
    # * :tags - Tags to be applied to RDS instance. The follow are required.  Arbitrary tags may also be added.
    #   * :environment - Environment  designation - can be anything.  Used to locate instance with other aws-tools
    #   * :purpose - Purpose  designation - can be anything.  Used to locate instance with other aws-tools
    #   * :name - Name will appear in the Aws web page if you set this
    #   * :snapshot_name - Name of the snapshot that will be used to construct the new instance.  This name will be matched with the  RDS db_instance_identifier.  The latest snapshot will be used.
    #   * :vpc_security_group_ids: - Comma separated list of security groups that will be applied to this instance
    def initialize(region, options = {})
      @region = region
      opts = options[:opts]
      if !options.has_key?(:instance)
        @id = opts[:db_instance_identifier]
        snapshot_name = options[:snapshot_name]
        if 0 < @region.find_db_instances({:instance_id => @id}).length
          log "Error, instance: #{@id} already exists"
          return
        end
        last = self.get_latest_db_snapshot({:snapshot_name => snapshot_name})
        log "Restoring: #{last.db_instance_identifier}, snapshot: #{last.db_instance_identifier} from : #{last.snapshot_create_time}"
        opts[:db_snapshot_identifier] = last.db_snapshot_identifier
        response = @region.rds.restore_db_instance_from_db_snapshot(opts)
        @_instance = response[:db_instance]
        @region.rds.add_tags_to_resource({:resource_name => "arn:aws:rds:#{@region.region}:#{@region.account_id}:db:#{@id}",
                                          :tags => [{:key => "environment", :value => options[:environment]},
                                                    {:key => "purpose", :value => options[:purpose]}]})

        self.wait

        opts = {:db_instance_identifier => @id,
                :vpc_security_group_ids => options[:vpc_security_group_ids]}
        @region.rds.modify_db_instance(opts)
      else
        @_instance = options[:instance]
        @id = @_instance[:db_instance_identifier]
      end
      @tags = {}
      _tags = @region.rds.list_tags_for_resource({:resource_name => "arn:aws:rds:#{@region.region}:#{@region.account_id}:db:#{@id}"})
      _tags[:tag_list].each do |t|
        @tags[t[:key].to_sym] = t[:value]
      end
      @endpoint = @_instance.endpoint[:address]
    end

    # Delete a database and be sure to capture a final stapshot
    # @return [Boolean] - A return value of true only means that the command was issued.  The caller should follow up later with a call to determine status in order to know when the delete has been completed
    def delete(options={})
      log "Deleting database: #{@id}"
      opts = {:db_instance_identifier => @id,
              :skip_final_snapshot => false,
              :final_db_snapshot_identifier => "#{@id}-#{Time.now.strftime("%Y-%m-%d-%H-%M-%S")}"}
      begin
        i = @region.rds.delete_db_instance(opts)
      rescue  Exception => e
        return false
      end
      true
    end

    # Purge db snapshots, keep just one - the latest
    # @return [Boolean]
    def purge_db_snapshots
      latest = 0
      @region.rds.describe_db_snapshots[:db_snapshots].each do |i|
        if i.snapshot_type == "manual" and i.db_instance_identifier == @id
          if i.snapshot_create_time.to_i > latest
            latest = i.snapshot_create_time.to_i
          end
        end
      end
      @region.rds.describe_db_snapshots[:db_snapshots].each do |i|
        if i.snapshot_type == "manual" and i.db_instance_identifier == @id
          if i.snapshot_create_time.to_i != latest
            log "Removing snapshot: #{i.db_snapshot_identifier}/#{i.snapshot_create_time.to_s}"
            begin
              @region.rds.delete_db_snapshot({:db_snapshot_identifier => i.db_snapshot_identifier})
            rescue
              log "Error removing snapshot: #{i.db_snapshot_identifier}/#{i.snapshot_create_time.to_s}"
              return false
            end
          else
            log "Keeping snapshot: #{i.db_snapshot_identifier}/#{i.snapshot_create_time.to_s}"
          end
        end
      end
      true
    end

    # Wait for the database to get to a state - we are usually waiting for it to be "available"
    # @param options [Hash] - Can be:
    # * :desired_status - Default: "available" - The RDS Status that is sought
    # * :timeout - Default: 600 seconds. - The time to wait for the status before returning failure
    # @return [Boolean]
    def wait(options = {:desired_status => "available",
                        :timeout => 600})
      inst = @region.find_db_instances({:instance_id => @id})[0]
      if !inst
        log "Error, instance: #{@id} not found"
        return false
      end
      t0 = Time.now.to_i
      while inst.status != options[:desired_status]
        inst = @region.find_db_instances({:instance_id => @id})[0]
        log "Database: #{@id} at #{@endpoint}.  Current status: #{inst.status}"
        if Time.now.to_i - t0 > options[:timeout]
          log "Timed out waiting for database: #{@id} at #{@endpoint} to move into status: #{options[:desired_status]}.  Current status: #{inst.status}"
          return false
        end
        sleep 20
      end
      return true
    end

    # Get the status of a database
    # @return [String] - Current status of this database
    def status
      @_instance.db_instance_status
    end

    # Get the name of the latest snapshot
    # @return [Hash] - Hash describing RDS Snapshot.  See [RDS Tech Docs](http://docs.aws.amazon.com/sdkforruby/api/Aws/RDS/V20130909.html)
    def get_latest_db_snapshot(options={})
      snapshot_name = options.has_key?(:snapshot_name) ? options[:snapshot_name] : @id

      last = nil
      last_t = 0
      @region.rds.describe_db_snapshots[:db_snapshots].each do |i|
        if i.db_instance_identifier == snapshot_name and (last.nil? or i.snapshot_create_time > last_t)
          last = i
          last_t = i.snapshot_create_time
        end
      end
      last
    end

  end

  # Class to handle EC2 Instances
  class AwsInstance  < AwsBase
    attr_accessor :id, :tags, :region, :private_ip, :public_ip, :_instance

    def initialize(region, options = {})
      @tags = {}
      @region = region
      if options.has_key?(:instance)
        @_instance = options[:instance]
        @id = @_instance[:instance_id]
        @public_ip = @_instance[:public_ip_address]
        @private_ip = @_instance[:private_ip_address]
      else
        resp = @region.ec2.run_instances(options[:template])
        raise "Error creating instance using options" if resp.nil? or resp[:instances].length <= 0
        @_instance = resp[:instances][0]
        @id = @_instance[:instance_id]
        @tags = options[:tags]
        self.add_tags(@tags)
        self.wait
        instance = @region.ec2.describe_instances(:instance_ids => [@id])[0][0].instances[0]
        @public_ip = instance[:public_ip_address]
        @private_ip = instance[:private_ip_address]
        raise "could not get ip address" if @public_ip.nil? && @private_ip.nil?
        self.inject_into_environment
      end
      @_instance.tags.each do |t|
        @tags[t[:key].to_sym] = t[:value]
      end
    end


    # Determine the state of an ec2 instance
    # @param use_cached_state [Boolean] - When true will use a cached version of the state rather than querying EC2 directly
    def state(use_cached_state=true)
      if !use_cached_state
        response = @region.ec2.describe_instances({instance_ids: [@id]})
        response[:reservations].each do |res|
          res[:instances].each do |inst|
            if inst[:instance_id] == @id
              return inst[:state][:name].strip()
            end
          end
        end
        return ""
      else
        @_instance.state[:name].strip()
      end
    end

    # Start an EC2 instance
    # @param wait [Boolean] - When true, will wait for instance to move into "running" state before returning
    def start(wait=false)
      if self.state(use_cached_state = false) != "stopped"
        log "Instance cannot be started - #{@region.region}://#{@id} is in the state: #{self.state}"
        return
      end
      log "Starting instance: #{@region.region}://#{@id}"
      @region.ec2.start_instances({:instance_ids => [@id]})
      if wait
        begin
          sleep 10
          log "Starting instance: #{@region.region}://#{@id} - state: #{self.state}"
        end while self.state(use_cached_state = false) != "running"
      end
      if @tags.has_key?("elastic_ip")
        @region.ec2.associate_address({:instance_id => @id, :public_ip => @tags['elastic_ip']})
        log "Associated ip: #{@tags['elastic_ip']} with instance: #{@id}"
      elsif @tags.has_key?("elastic_ip_allocation_id")
        @region.ec2.associate_address({:instance_id => @id, :allocation_id => @tags['elastic_ip_allocation_id']})
        log "Associated allocation id: #{@tags['elastic_ip_allocation_id']} with instance: #{@id}"
      end
      if @tags.has_key?("elastic_lb")
        self.add_to_lb(@tags["elastic_lb"])
        log "Adding instance: #{@id} to '#{@tags['elastic_lb']}' load balancer"
      end
    end

    # Add tags to an instance
    # @param h_tags [Hash] - Hash of tags to add to instance
    def add_tags(h_tags)
      tags = []
      h_tags.each do |k, v|
        tags << {:key => k.to_s, :value => v}
      end
      resp = @region.ec2.create_tags({:resources => [@id],
                                      :tags => tags})
    end

    # Add an instance to an elastic lb
    # @param lb_name [String] - Name of elastic load balancer
    def add_to_lb(lb_name)
      @region.elb.register_instances_with_load_balancer({:load_balancer_name => lb_name,
                                                         :instances => [{:instance_id => @id}]})
    end

    # Remove instance from elastic lb
    # @param instance [AwsInstance] Instance to remove from lb
    # @param lb_name [String] Lb name from which the instance is to be removed
    # @return [Aws::PageableResponse]
    def remove_from_lb(lb_name)
      lb = @region.elb.describe_load_balancers({:load_balancer_names => [lb_name]})
      if lb and lb[:load_balancer_descriptions].length > 0
        lb[:load_balancer_descriptions][0][:instances].each do |lb_i|
          if lb_i[:instance_id] == @id
            @elb.deregister_instances_from_load_balancer({:load_balancer_name => lb_name,
                                                          :instances => [{:instance_id => @id}]})
            sleep 30
          end
        end
      end
    end

    # Terminates ec2 instance
    def terminate()
      eject_from_environment
      @region.ec2.terminate_instances({:instance_ids => [@id]})
    end

    # Stops an ec2 instance
    # @param wait [Boolean] - When true, will wait for the instance to be completely stopped before returning
    def stop(wait=false)
      if self.state(use_cached_state = false) != "running"
        log "Instance cannot be stopped - #{@region.region}://#{@id} is in the state: #{self.state}"
        return
      end
      self.eject_from_environment
      if @tags.has_key?("elastic_lb")
        log "Removing instance: #{@id} from '#{@tags['elastic_lb']}' load balancer"
        remove_from_lb(tags["elastic_lb"])
      end
      log "Stopping instance: #{@region.region}://#{@id}"
      @region.ec2.stop_instances({:instance_ids => [@id]})
      while self.state(use_cached_state = false) != "stopped"
        sleep 10
        log "Stopping instance: #{@region.region}://#{@id} - state: #{self.state}"
      end if wait
      if self.state(use_cached_state = false) == "stopped"
        log "Instance stopped: #{@region.region}://#{@id}"
      end
    end

    # Connects using ssh to an ec2 instance
    def connect
      if self.state(use_cached_state = false) != "running"
        log "Cannot connect, instance: #{@region.region}://#{@id} due to its state: #{self.state}"
        return
      end
      ip = self.public_ip != "" ? self.public_ip : self.private_ip
      log "Connecting: ssh #{@tags[:user]}@#{ip}"
      exec "ssh #{@tags[:user]}@#{ip}"
    end
    def eject_from_environment
      if @tags.has_key?(:elastic_lb)
        log "Removing instance: #{@id} from '#{@tags[:elastic_lb]}' load balancer"
        self.remove_from_lb(tags[:elastic_lb])
      end
      if @tags.has_key?(:security_groups_foreign)
        self.revoke_sg_ingress(@tags[:security_groups_foreign].split(","))
      end
    end

    def inject_into_environment
      if @tags.has_key?(:elastic_ip)
        @region.ec2.associate_address({:instance_id => @id, :public_ip => @tags[:elastic_ip]})
        log "Associated ip: #{@tags[:elastic_ip]} with instance: #{@id}"
      elsif @tags.has_key?(:elastic_ip_allocation_id)
        @region.ec2.associate_address({:instance_id => @id, :allocation_id => @tags[:elastic_ip_allocation_id]})
        log "Associated allocation id: #{@tags[:elastic_ip_allocation_id]} with instance: #{@id}"
      end
      if @tags.has_key?(:mount_points)
        mounts = @tags[:mount_points].split(";")
        mounts.each do |mnt|
          (volume_id,device) = mnt.split(",")
          log "Mounting volume: #{volume_id} on #{device}"
          self.mount(volume_id, device)
        end
      end
      if @tags.has_key?(:security_group_ids)
        self.set_security_groups(@tags[:security_group_ids].split(","))
      end
      if @tags.has_key?(:security_groups_foreign)
        self.authorize_sg_ingress(@tags[:security_groups_foreign].split(","))
      end

      # if any of the above fails, we probably do not want it in the lb
      if @tags.has_key?(:elastic_lb)
        self.add_to_lb(@tags[:elastic_lb])
        log "Adding instance: #{@id} to '#{@tags[:elastic_lb]}' load balancer"
      end
    end
    def wait(options = {:timeout => 300, :desired_status => "running"})
      t0 = Time.now.to_i
      begin
        sleep 10
        log "Waiting on instance: #{@region.region}://#{@id} - current state: #{self.state}"
        return if Time.now.to_i - t0 > options[:timeout]
      end while self.state(use_cached_state = false) != options[:desired_status]
    end

    def set_security_groups(groups)
      # only works on instances in a vpc
      @region.ec2.modify_instance_attribute({:instance_id => @id, :groups => groups})
    end

    # Does a security group allow ingress on a port for the public IP of this instance
    # @param group_port [String] - security_group:port  like "sg_xxxxxx:8080"
    # @return [Boolean] true if the security group allows ingress for the public IP of this instance on a certain port
    def has_sg_rule?(group_port)
      options = get_simple_sg_options(group_port)
      options_cidr_ip = options[:ip_permissions][0][:ip_ranges][0][:cidr_ip]
      group_id = options[:group_id]
      raise "missing security group_id" if group_id.nil?
      sg = @region.ec2.describe_security_groups(:group_ids => [group_id]).data.security_groups[0]
      sg.ip_permissions.each do |p|
        if p.ip_protocol == "tcp" &&
            p.from_port == options[:ip_permissions][0][:from_port] &&
            p.to_port == options[:ip_permissions][0][:to_port]
          p[:ip_ranges].each do |ipr|
            return true if ipr.cidr_ip == options_cidr_ip
          end
        end
      end
      false
    end

    # authorize security group ingress for public ip of this instance on port
    # @param groups [Array] - each element is String: "security_group_id:port". For example: ["sg-0xxxxx:80", "sg-0xxxxx:8443", "sg-0yyyyy:3000"]
    def authorize_sg_ingress(groups)
      raise "no public ip" unless @public_ip.to_s.match /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
      groups.each do |gp|
        options = get_simple_sg_options(gp)
        if has_sg_rule?(gp)
          log "security group rule #{gp} for #{self.public_ip} already exists"
        else
          @region.ec2.authorize_security_group_ingress options
          log "added #{self.public_ip} to security group for :port #{gp}"
        end
      end
    end

    # revoke security group ingress for public ip of this instance on port
    # @param groups [Array] - each element is String: "security_group_id:port". For example: ["sg-0xxxxx:80", "sg-0xxxxx:8443", "sg-0yyyyy:3000"]
    def revoke_sg_ingress(groups)
      # revoke the public ip of this instance for ingress on port for security group
      # groups is array of strings: security_group_id:port
      raise "no public ip" unless @public_ip.to_s.match /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
      groups.each do |gp|
        options = get_simple_sg_options(gp)
        if has_sg_rule?(gp)
          @region.ec2.revoke_security_group_ingress options
          log "removed #{self.public_ip} from security group for :port #{gp}"
        else
          log "not removing #{self.public_ip} rule #{gp} because it does not exist"
        end
      end
    end
    def mount(volume_id, device)
      @region.ec2.attach_volume({:instance_id => @id,
                                 :volume_id => volume_id,
                                 :device => device})
    end

    # construct hash for authorize/revoke ingress and has_sg_rule?
    # @param group_id_port [String] - security_group:port  like "sg_xxxxxx:8080"
    # @return [Hash] - Hash for ec2 call for security group management
    def get_simple_sg_options(group_id_port)
      security_group_id, port = group_id_port.split(':')
      port = port.to_s.to_i
      raise "no security group id" unless security_group_id.to_s.length > 0
      raise "no, or invalid port" unless port.to_s.to_i > 0
      {:group_id => security_group_id,
       :ip_permissions => [ :ip_protocol => "tcp",
                            :from_port => port,
                            :to_port => port,
                            :ip_ranges => [:cidr_ip => "#{self.public_ip}/32"]
                          ]
      }
    end


  end
end
