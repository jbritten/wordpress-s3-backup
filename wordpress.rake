# Backup your WordPress database and site to Amazon S3
#
# Author:    Justin Britten [justin at compulsivoco dot com]
# Copyright: 2009 Compulsivo, Inc.
# License:   MIT License (http://www.opensource.org/licenses/mit-license.php)
#
#  $ rake -f wordpress.rake -T
#    rake wordpress:backup              # Backup both the WordPress database and site
#    rake wordpress:backup:db           # Backup the WordPress database to S3
#    rake wordpress:backup:site         # Backup the WordPress site to S3
#    rake wordpress:manage:list         # List all your backups
#    rake wordpress:manage:cleanup      # Remove all but the last 10 most recent backups or optionally specify KEEP=5 to keep the last 5
#    rake wordpress:retrieve            # Retrieve the latest WordPress database and site backup from S3 (optionally specify VERSION=file_name)
#    rake wordpress:retrieve:db         # Retrieve the latest WordPress database backup from S3 (optionally specify VERSION=file_name)
#    rake wordpress:retrieve:site       # Retrieve the latest WordPress site backup from S3 (optionally specify VERSION=file_name)
#
# Prerequisites
#
#   1.  You'll need to install the aws-s3 gem.
#       $ sudo gem install aws-s3
#
#   2.  Specify your database credentials, site path, and Amazon S3 access keys below.
#
# Execution
#
#   $ rake -f wordpress.rake wordpress:backup
#
# Automation
#
#   Put this in your crontab to run nightly backups at 3am:
#     0 3 * * * rake -f /PATH/TO/wordpress.rake wordpress:backup
#

require 'rubygems'
require 'aws/s3'

#
# CUSTOMIZE THE FOLLOWING:
#
#   DBNAME        - The name of your WordPress mysql database. You can get this from the wp-config.php file of your wordpress installation.
#   DBUSER        - The username of your WordPress mysql database. You can get this from the wp-config.php file of your wordpress installation.
#   DBPASSWORD    - The password your WordPress mysql database. You can get this from the wp-config.php file of your wordpress installation.
#   PATHTOSITE    - The path to your WordPress blog. For example, /home/USER/public_html
#   S3ACCESSKEYID - Your access key ID for Amazon S3
#   S3SECRETKEY   - Your secret access key for Amazon S3
#   S3BUCKETNAME  - The name of the bucket where the backups will be stored.  No spaces or weird characters.  Underscores are okay.

DBNAME = "your wordpress database name"
DBUSER = "your wordpress database username"
DBPASSWORD = "your wordpress database password"
PATHTOSITE = "/YOUR/HOME/public_html"
S3ACCESSKEYID = "your Amazon S3 access id"
S3SECRETKEY = "your Amazon S3 secret key"
S3BUCKETNAME = "name_of_your_blog"



namespace :wordpress do

  desc "Backup WordPress database and site to Amazon S3"
  task :backup => [ "wordpress:backup:db", "wordpress:backup:site"]

  namespace :backup do
    desc "Backup the WordPress database to S3"
    task :db  do
      s3_connect
      
      msg "Initiating database backup"
      make_bucket('db')
      backup = "/tmp/#{backup_name('db')}"

      msg "Dumping database"
      cmd = "mysqldump --opt --skip-add-locks -u#{DBUSER} "
      puts cmd + "... [password filtered]"
      cmd += " -p'#{DBPASSWORD}' " unless DBPASSWORD.empty?
      cmd += " #{DBNAME} > #{backup}"
      result = system(cmd)
      raise("ERROR: mysqldump failed (#{$?})") unless result

      s3_transmit('db', backup)
    end

    desc "Backup the WordPress site to S3"
    task :site  do
      s3_connect

      msg "Initiating site backup"
      make_bucket('site')
      backup = "/tmp/#{backup_name('site')}"

      cmd = "cp -rp #{PATHTOSITE} #{backup}"
      msg "Making copy of site"
      puts cmd
      result = system(cmd)      
      raise("Copy of site failed (#{$?})") unless result

      s3_transmit('site', backup)
    end

  end # end backup namespace

  desc "Retrieve the latest WordPress database and site backup from S3.  If you need to specify a specific version, call the individual retrieve tasks."
  task :retrieve => [ "wordpress:retrieve:db",  "wordpress:retrieve:site"]

  namespace :retrieve do
    desc "Retrieve the latest WordPress database backup from S3 (optionally specify VERSION=file_name)"
    task :db  do
      retrieve_file 'db', ENV['VERSION']
    end

    desc "Retrieve the latest WordPress site backup from S3 (optionally specify VERSION=file_name)"
    task :site do
      retrieve_file 'site', ENV['VERSION']
    end

  end #end retrieve namespace
  
  namespace :manage do
    desc "Remove all but the last 10 most recent backups or optionally specify KEEP=5 to keep the last 5"
    task :cleanup  do
      s3_connect
      keep_num = ENV['KEEP'] ? ENV['KEEP'].to_i : 10
      puts "Keeping the last #{keep_num}"
      cleanup_bucket('db', keep_num)
      cleanup_bucket('site', keep_num)
    end

    desc "Vist all your WordPress backups"
    task :list  do
      s3_connect
      print_bucket 'db'
      print_bucket 'site'
    end

  end #end manage namespace
end

  private
  
  # Open a connection to Amazon S3  
  def s3_connect
    AWS::S3::Base.establish_connection!(:access_key_id => "#{S3ACCESSKEYID}", :secret_access_key => "#{S3SECRETKEY}")
  end

  # Zip up the files and send to S3
  def s3_transmit(name, tmp_file)
    backup = "/tmp/#{backup_name(name)}.tar.gz"

    msg "Building tar backup for #{name}"
    cmd = "tar -cpzf #{backup} #{tmp_file}"
    puts cmd
    system cmd

    msg "Sending #{name} backup to S3"
    AWS::S3::S3Object.store(backup.split('/').last, open(backup), bucket_name(name), :access => :private)
    msg "Finished sending #{name} to S3"

    msg "Cleaning up"
    cmd = "rm -rf #{backup} #{tmp_file}"
    puts cmd
    system cmd  
  end
  
  # Obtain a file from S3
  def s3_retrieve(bucket, specific_file)
    msg "Retrieving #{specific_file} from #{bucket} on S3"
    open(specific_file, 'w') do |file|
      AWS::S3::S3Object.stream(specific_file, bucket) do |chunk|
        file.write chunk
      end
    end
    msg "Retrieved #{specific_file} from #{bucket} on S3"
  end
  
  def retrieve_file(name, specific_file)
    s3_connect

    if specific_file
      if AWS::S3::S3Object.exists?(specific_file, bucket_name(name))
        s3_retrieve(bucket_name(name), specific_file)
      else
        msg "Couldn't find #{specific_file} in #{bucket_name(name)} on S3"
      end
    else
      # Just get the latest backup file
      objects = AWS::S3::Bucket.objects(bucket_name(name))
      s3_retrieve(bucket_name(name), objects[objects.size-1].key)
    end
    
  end

  # Print all backups in a particular bucket
  def print_bucket(name)
    msg "Showing contents of #{bucket_name(name)}"
    bucket = AWS::S3::Bucket.find(bucket_name(name))
    bucket.objects.each do |object|
      size = format("%.2f", object.size.to_f/1048576)
      puts "Name: #{object.key} (#{size}MB)"
    end
  end

  # Remove all but KEEP_NUM objects from a particular bucket
  def cleanup_bucket(name, keep_num)
    msg "Cleaning up #{bucket_name(name)} (keeping last #{keep_num})"
    bucket = AWS::S3::Bucket.find(bucket_name(name))
    objects = bucket.objects
    remove = objects.size-keep_num-1
    objects[0..remove].each do |object|
      response = object.delete
    end unless remove < 0
  end

  def make_bucket(name)
    AWS::S3::Bucket.create(bucket_name(name))
    msg "Using bucket #{bucket_name(name)}"
  end
  
  def bucket_name(name)
    "#{S3BUCKETNAME}_#{name}"
  end

  def backup_name(name)
    @timestamp ||= Time.now.utc.strftime("%Y%m%d%H%M%S")
    name.sub('_', '.') + ".#{@timestamp}"
  end

  def msg(text)
    puts " -- WordPress backup status: #{text}"
  end

