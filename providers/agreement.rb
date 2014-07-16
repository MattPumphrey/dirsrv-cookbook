# Cookbook Name:: dirsrv
# Provider:: agreement
#
# Copyright 2014, Alan Willis <alwillis@riotgames.com>
#
# All rights reserved
#

def whyrun_supported?
  true
end

action :create do

  # Start with attributes that are common to both Active Directory and Directory Server
  attrs = {
      cn: new_resource.label,
      description: "#{new_resource.suffix} on #{new_resource.replica_host}",
      nsDS5ReplicaPort: new_resource.replica_port.to_s,
      nsDS5ReplicaBindDN: new_resource.replica_bind_dn,
      nsDS5ReplicaBindMethod: new_resource.replica_bind_method,
      nsDS5ReplicaTransportInfo: new_resource.replica_transport,
      nsDS5ReplicaUpdateSchedule: new_resource.replica_update_schedule,
      nsDS5ReplicaRoot: new_resource.suffix
  }

  # Ensure that bind method requirements are satisfied 
  case new_resource.replica_bind_method
  when 'SIMPLE', 'SASL/DIGEST-MD5'
    if new_resource.replica_bind_dn.nil? or new_resource.replica_credentials.nil?
      Chef::Application.fatal!("The SIMPLE and SASL/DIGEST-MD5 bind methods require both replica_bind_dn and replica_credentials")
    end
  when 'SSLCLIENTAUTH'
    if new_resource.replica_transport == 'LDAP'
      Chef::Application.fatal!("The SSLCLIENTAUTH bind method requires replica_transport to be either SSL or TLS")
    end
  when 'SASL/GSSAPI'
    unless new_resource.replica_transport == 'LDAP'
      Chef::Application.fatal!("The SASL/GSSAPI bind method requires replica_transport to be set to LDAP")
    end
  end

  # Setup remote directory type stuff

  if new_resource.directory_type == :AD
    attrs[:objectClass] = [ 'top', 'nsDSWindowsReplicationAgreement' ]
    attrs[:nsDS7NewWinUserSyncEnabled] = new_resource.ad_new_user_sync if new_resource.ad_new_user_sync
    attrs[:nsDS7NewWinGroupSyncEnabled] = new_resource.ad_new_group_sync if new_resource.ad_new_group_sync
    attrs[:oneWaySync] = new_resource.ad_one_way_sync if new_resource.ad_one_way_sync
    attrs[:winSyncInterval] = new_resource.ad_sync_interval if new_resource.ad_sync_interval
    attrs[:winSyncMoveAction] = new_resource.ad_sync_move_action if new_resource.ad_sync_move_action

    if new_resource.ad_domain.nil?
      Chef::Application.fatal!("Must specify ad_domain to synchronize with Active Directory") 
    else
      attrs[:nsDS7WindowsDomain] = new_resource.ad_domain
    end

    if new_resource.ad_replica_subtree.nil?
      Chef::Application.fatal!("Must specify ad_replica_subtree to synchronize with Active Directory")
    else
      attrs[:nsDS7WindowsReplicaSubtree] = new_resource.ad_replica_subtree
      attrs[:nsDS7DirectoryReplicaSubtree] = "#{new_resource.ad_replica_subtree},#{new_resource.suffix}"
    end
  else
    attrs[:objectClass] = [ 'top', 'nsDS5ReplicationAgreement' ]
    attrs[:nsDS5ReplicaHost] =  new_resource.replica_host
    attrs[:nsDS5ReplicatedAttributeList] = new_resource.ds_replicated_attribute_list
    attrs[:nsDS5ReplicatedAttributeListTotal] = new_resource.ds_replicated_attribute_list_total
  end

  converge_by("Replication agreement #{new_resource.label} for #{new_resource.suffix}") do

    if new_resource.directory_type == :AD
      dirsrv_plugin "Posix Winsync API" do
        host   new_resource.host
        port   new_resource.port
        credentials new_resource.credentials
        action :enable
      end
    end

    dirsrv_entry "cn=#{new_resource.label},cn=replica,cn=\"#{new_resource.suffix}\",cn=mapping tree,cn=config" do
      host   new_resource.host
      port   new_resource.port
      credentials new_resource.credentials
      attributes attrs
      if new_resource.replica_credentials and new_resource.directory_type == :AD
        seed_attributes ({ 'nsDS5ReplicaBindCredentials' => new_resource.replica_credentials })
      elsif new_resource.replica_credentials
        seed_attributes ({ 'nsDS5ReplicaCredentials' => new_resource.replica_credentials })
      end
    end
  end
end

action :create_and_initialize do

  action_create

  converge_by("Conditional initialization of #{new_resource.label} agreement for #{new_resource.suffix} database on #{new_resource.replica_host}") do

    ruby_block "initialize-#{new_resource.label}-#{new_resource.replica_host}" do
      block do

        # Setup connection
        dirsrv = Chef::Dirsrv.new
        connection = Hash.new
        connection.class.module_eval { attr_accessor :dn, :host, :port, :credentials }
        connection.dn = "cn=#{new_resource.label},cn=replica,cn=\"#{new_resource.suffix}\",cn=mapping tree,cn=config"
        connection.host = new_resource.host
        connection.port = new_resource.port
        connection.credentials = new_resource.credentials

        # why run check
        entry = dirsrv.get_entry( connection )

        if entry[:nsDS5ReplicaUpdateInProgress].first != 'FALSE'
          Chef::Log.info("Skipping initialization of #{new_resource.label} for replica #{new_resource.suffix}: update in progress")
        elsif ( entry[:nsDS5ReplicaLastInitStart].first != '0' and entry[:nsDS5ReplicaLastInitEnd].first != '0' ) or /^CHEF_INITIALIZED/.match( entry[:description].first )
          Chef::Log.info("Skipping initialization of #{new_resource.label} for replica #{new_resource.suffix}: already initialized")
        else

          # Initialize and verify
          dirsrv.modify_entry( connection, [ [ :add, :nsDS5BeginReplicaRefresh, 'start' ], [ :replace, :description, "CHEF_INITIALIZED: #{entry[:description].first}" ] ] )

          for count in 1 .. 5
            entry = dirsrv.get_entry( connection )
            init_status = entry[:nsDS5ReplicaLastInitStatus].first
            break if /^0/.match( init_status ) 
            sleep 1
            if count == 5
              Chef::Log.error("Error during initialization: #{init_status}")
            end
          end
        end
      end
    end
  end
end