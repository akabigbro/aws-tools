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
  attr_accessor :ec2, :region, :rds, :account_id, :elb, :cw, :s3
  REGIONS = {'or' => "us-west-2", 'ca' => "us-west-1", 'va' => 'us-east-1'}

  # @param region [String] - must be one of the keys of the REGIONS static hash
  # @param account_id [String] - Aws account id
  # @param access_key_id [String] - Aws access key id
  # @param secret_access_key [String] - Aws secret access key
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
  end

  # Simple EC2 Intance finder.  Can find using instance_id, or using
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

  # Simple DB Intance finder.  Can find using instance_id, or using
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

# Methods for dealing with CloudWatch
  class AwsCw  < AwsBase
    attr_accessor :region

    # @params - region [String] - Value from REGION static hash
    def initialize(region, options={})
      @region = region
    end

    # Put a cw metric
    # @params - arg_csv [String] - CSV row: "namespace,name,value,dims"
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
    # @params - region [String]  - Value from REGION static hash
    # @params - options [Hash] - Possible values:
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
    # @params - filename [String]  - local file name
    # @params - file_identity [String] - S3 file path
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
    # example: put_local_file {:bucket=>"bucket", :local_file_path=>"/tmp/bar/foo.txt", :aws_path=>"b"}
    # would make an s3 object named foo.txt in bucket/b
    # @params - local_file_path [String] - Location of file to put
    # @params - aws_path [String] - S3 path to put the file
    # @params - options [Hash] - Can contain any valid S3 bucket options see [docs](http://docs.aws.amazon.com/sdkforruby/api/frames.html)
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
    # @params - options [Hash] - Can contain:
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
    # example: get( {:s3_path_to_object=>development/myfile.txt',
    #                :dest_file_path=>'/tmp/foo.txt'})
    #          would write to local /tmp/foo.txt a file retrieved from s3
    #          at development/myfile.txt
    # @params - options [Hash] - Can contain:
    # * :s3_path_to_object - S3 object path
    # * :dest_file_path - local file were file will be written
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
        File.open(dest_file_path, 'wb') do |file|
          response.body.each { |chunk| file.write chunk }
        end
      rescue Exception => e
        return false
      end
      true
    end

    # deletes from s3 an object at :s3_path_to_object
    # @params - options [Hash] - Can be:
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
    # @params - region [String] - - Value from REGION static hash
    # @params - options [Hash] - Can contain:
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
    #   * :snapshot_name - Name of
    #   * :vpc_security_group_ids: sg-24010b46


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
    def delete(options={})
      log "Deleting database: #{@id}"
      opts = {:db_instance_identifier => @id,
              :skip_final_snapshot => false,
              :final_db_snapshot_identifier => "#{@id}-#{Time.now.strftime("%Y-%m-%d-%H-%M-%S")}"}
      i = @region.rds.delete_db_instance(opts)
    end

    # Purge db snapshots, keep just one - the latest
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
            end
          else
            log "Keeping snapshot: #{i.db_snapshot_identifier}/#{i.snapshot_create_time.to_s}"
          end
        end
      end
    end

    # Wait for the database to get to a state - we are usually waiting for it to be "available"
    def wait(options = {:desired_status => "available",
                        :timeout => 600})
      inst = @region.find_db_instances({:instance_id => @id})[0]
      if !inst
        log "Error, instance: #{@id} not found"
        return
      end
      t0 = Time.now.to_i
      while inst.status != options[:desired_status]
        inst = @region.find_db_instances({:instance_id => @id})[0]
        log "Database: #{@id} at #{@endpoint}.  Current status: #{inst.status}"
        if Time.now.to_i - t0 > options[:timeout]
          log "Timed out waiting for database: #{@id} at #{@endpoint} to move into status: #{options[:desired_status]}.  Current status: #{inst.status}"
          return
        end
        sleep 20
      end
    end

    # Get the status of a database
    def status
      @_instance.db_instance_status
    end

    # Get tthe name of the latest snapshot
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
      @region = region
      if !options.has_key?(:instance)
        resp = @region.ec2.run_instances(options)
        raise "Error creating instance using options" if resp.nil? or resp[:instances].length <= 0
        @_instance = resp[:instances][0]
      else
        @_instance = options[:instance]
      end
      @id = @_instance[:instance_id]
      @tags = {}
      @_instance.tags.each do |t|
        @tags[t[:key].to_sym] = t[:value]
      end
      @public_ip = @_instance[:public_ip_address]
      @private_ip = @_instance[:private_ip_address]
    end

    # Determine the state of an ec2 instance
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

    # Set security groups on an instance
    def set_security_groups(groups)
      resp = @region.ec2.modify_instance_attribute({:instance_id => @id,
                                                    :groups => groups})
    end

    # Add tags to an instance
    def add_tags(h_tags)
      tags = []
      h_tags.each do |k, v|
        tags << {:key => k.to_s, :value => v}
      end
      resp = @region.ec2.create_tags({:resources => [@id],
                                      :tags => tags})
    end

    # Add an instance to an elastic lb
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
          end
        end
      end
    end

    # Terminates ec2 instance
    def terminate()
      @region.ec2.terminate_instances({:instance_ids => [@id]})
    end

    # Stops an ec2 instance
    def stop(wait=false)
      if self.state(use_cached_state = false) != "running"
        log "Instance cannot be stopped - #{@region.region}://#{@id} is in the state: #{self.state}"
        return
      end
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
  end
end
