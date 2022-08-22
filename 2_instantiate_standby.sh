#!/bin/bash

###########################
# Add source standby logs #
###########################
add_source_standby_logs () {
echo "$function_header"
echo "Started $FUNCNAME"
standby_dir=$( ssh oracle@$srchost "df -mP|grep $srcsid|grep -e redo -e db0|awk '//{print \$4, \$6}'|sort -nr|head -1|awk '//{print \$2}'" )
if [ -z "$standby_dir" ] ; then
  echo "Standby directory was not set; exiting"
  exit 1
else
  echo "standby_dir is $standby_dir"
fi
EXEC_SQL_ON_SRC "
alter database add standby logfile '${standby_dir}/stdbyredo1.log' size ${logsize}m reuse;
alter database add standby logfile '${standby_dir}/stdbyredo2.log' size ${logsize}m reuse;
alter database add standby logfile '${standby_dir}/stdbyredo3.log' size ${logsize}m reuse;
alter database add standby logfile '${standby_dir}/stdbyredo4.log' size ${logsize}m reuse;
"
echo "Completed $FUNCNAME"
}

############################
# Add target oratab oramon #
############################
add_target_oratab_oramon () {
echo "$function_header"
echo "Started $FUNCNAME"
set_oratab_oramon_entries
if ! ssh oracle@$tgthost cat /etc/oratab|grep -q $srcsid ; then
  echo $tgt_oratab_entry| ssh oracle@$tgthost 'cat >>/etc/oratab';
  echo "Added $tgt_oratab_entry to target oratab"
else
  echo "Oratab entry already exists on target"
fi

if ! ssh oracle@$tgthost cat /software/oracle/oramon|grep -q $srcsid ; then
  echo $tgt_oramon_entry| ssh oracle@$tgthost 'cat >>/software/oracle/oramon';
  echo "Added $tgt_oramon_entry to target oramon"
else
  echo "Oramon entry already exists on target"
fi
echo "Completed $FUNCNAME"
}

######################################
# Backup listener and tnsnames files #
######################################
backup_listener_and_tnsnames_files () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost chmod -R 775 /upapps/oracle/dba/network/admin
ssh oracle@$tgthost chmod -R 775 /upapps/oracle/dba/network/admin

# source files
if ! ssh oracle@$srchost test -f /tmp/listener${srcsid}.ora.backup ; then
  ssh oracle@$srchost "cp -p /upapps/oracle/dba/network/admin/listener.ora /tmp/listener${srcsid}.ora.backup"
fi
if ! ssh oracle@$srchost test -f /tmp/tnsnames${srcsid}.ora.backup ; then
  ssh oracle@$srchost "cp -p /upapps/oracle/dba/network/admin/tnsnames.ora /tmp/tnsnames${srcsid}.ora.backup"
fi

# target files
if ! ssh oracle@$tgthost test -f /tmp/listener${tgtsid}.ora.backup ; then
  ssh oracle@$tgthost "cp -p /upapps/oracle/dba/network/admin/listener.ora /tmp/listener${tgtsid}.ora.backup"
fi
if ! ssh oracle@$tgthost test -f /tmp/tnsnames${tgtsid}.ora.backup ; then
  ssh oracle@$tgthost "cp -p /upapps/oracle/dba/network/admin/tnsnames.ora /tmp/tnsnames${tgtsid}.ora.backup"
fi
if ! ssh oracle@$tgthost test -f /tmp/tnsnames${tgtsid}.ora.backup ; then
  ssh oracle@$tgthost "cp -p /upapps/oracle/dba/network/admin/tnsnames.ora /tmp/tnsnames${tgtsid}.ora.backup"
fi
echo "Completed $FUNCNAME"
}

#######################
# Backup source pfile #
#######################
backup_source_pfile () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "create pfile='/privdir/oracle/backup_pfile_$srcsid.ora' from spfile;"
echo "Completed $FUNCNAME"
}

#######################
# Change SYS password #
#######################
change_sys_password () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "alter user sys identified by $sys_password;"
echo "Completed $FUNCNAME"
}

############################################
# Copy gold copy of bash_profile to target #
############################################
copy_gold_bash_profile_to_target() {
echo "$function_header"
echo "Started $FUNCNAME"
scp /upapps/dte/oracle-farm-migration/v1.0/.bash_profile oracle@$tgthost:/privdir/oracle/.bash_profile;
echo "Completed $FUNCNAME"
}

################################
# Copy password file to target #
################################
copy_password_file_to_target() {
echo "$function_header"
echo "Started $FUNCNAME"
save_sys_password
change_sys_password

scp oracle@$srchost:$src_oracle_home/dbs/orapw${srcsid} /tmp/orapw${tgtsid};
scp /tmp/orapw${tgtsid} oracle@$tgthost:$tgt_oracle_home/dbs/orapw${tgtsid};
echo "Completed $FUNCNAME"
}

#########################
# Copy wallet to target #
#########################
copy_wallet_to_target () {
echo "$function_header"
echo "Started $FUNCNAME"
if ssh oracle@$srchost "[ -d /software/oracle/admin/$srcdb_unique_name/wallet ]" ; then
  echo 'Wallet directory exists on source; copying to target'
  if ! ssh oracle@$tgthost "[ -d /software/oracle/admin/$tgtdb_unique_name/wallet/tde ]" ; then
    ssh oracle@$tgthost "mkdir -p /software/oracle/admin/$tgtdb_unique_name/wallet/tde"
  fi
  if [ -d /tmp/${srcsid}/wallet ] ; then
    rm /tmp/${srcsid}/wallet/*
  else
    mkdir -p /tmp/${srcsid}/wallet
  fi
  scp -r oracle@$srchost:/software/oracle/admin/$srcsid/wallet/* /tmp/${srcsid}/wallet;
  scp -r /tmp/${srcsid}/wallet/* oracle@$tgthost:/software/oracle/admin/$tgtdb_unique_name/wallet/tde;
  echo 'Wallet copied to target'
else
  echo 'Wallet directory does not exist on source'
fi
echo "Completed $FUNCNAME"
}

#####################
# Check environment #
#####################
check_environment () {
echo "$function_header"
echo "Started $FUNCNAME"
get_pord
if [[ $pord == "p" ]]; then
        if  ssh oracle@$tgthost "grep -q -e ^dev -e ^test -e ^xtst  -e ^dsd -e ^dst -e ^dsx /etc/oratab"; then
                echo "ERROR! dev/test SID found on target /etc/oratab; exiting"
                exit 1
        fi
else
        if  ssh oracle@$tgthost "grep -q -e ^prod -e ^dsp /etc/oratab"; then
                echo "ERROR! prod SID found in target /etc/oratab; exiting"
                exit 1
        fi
fi
echo "Completed $FUNCNAME"
}

#################################
# Check source archivelog count #
#################################
check_source_archivelog_count() {
echo "$function_header"
echo "Started $FUNCNAME"
archivelog_count=$( ssh  oracle@$srchost ls ${source_db_base}/${srcsid}/archive001|wc -l );
echo "$archivelog_count archivelog(s) is on host server"
if [[ $arch_ct = 0 ]] ; then
 echo 'Error! At least one archive log must be available; exiting';
 exit 1;
fi
echo "Completed $FUNCNAME"
}

##############################
# Create db base directories #
##############################
create_target_db_base_directories () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "
mkdir -p /oratemp/$tgtsid/standby_archive001
mkdir -p $target_db_base/$tgtsid/dbs
mkdir -p $target_db_base/$tgtsid/fra
mkdir -p $target_db_base/$tgtsid/logs/audit
mkdir -p $target_db_base/$tgtsid/logs/logminer
mkdir -p $target_db_base/$tgtsid/logs/diag/rdbms/${tgtsid}
cd $target_db_base/$tgtsid/logs/diag/rdbms/
ln -s $target_db_base/$tgtsid/logs/diag/rdbms/$srcdb_unique_name $tgtdb_unique_name
mkdir -p $target_db_base/$tgtsid/${standby_dir}
#mkdir -p $( echo "${standby_dir/oradata/oratemp}" )
"
echo "Completed $FUNCNAME"
}


#############################################
# Enable Java on Source for PSU apply later #
#############################################
enable_java () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC 'exec dbms_java_dev.enable;'
echo "Completed $FUNCNAME"
}


##########################
# Finalize instantiation #
##########################
finalize_instantiation() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC 'alter system archive log current;'
EXEC_SQL_ON_TGT 'alter database recover managed standby database using current logfile disconnect;'
echo "Completed $FUNCNAME"
}

#####################
# Get Redo Log Size #
#####################
get_redo_log_size () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select distinct to_char(round(bytes/1024/1024)) from v\$log;'
logsize=$sql_result
echo "Redo log size is $logsize MB"
echo "Completed $FUNCNAME"
}

##############################
# Prep source for data guard #
##############################
prep_source_for_data_guard () {
echo "$function_header"
echo "Started $FUNCNAME"

get_redo_log_size
add_source_standby_logs
set_source_data_guard_parms

echo "Completed $FUNCNAME"
}

####################
# Reload listeners #
####################
reload_listeners() {
echo "$function_header"
echo "Started $FUNCNAME"
echo "Reloading source listener"
ssh  oracle@$srchost "
. /upapps/oracle/dba/scripts/pathsetup $srcsid
lsnrctl reload
"
echo "Reloading target listener"
ssh  oracle@$tgthost "
. /upapps/oracle/dba/scripts/pathsetup $tgtsid
lsnrctl reload
"
echo "Completed $FUNCNAME"
}


######################
# Reset SYS password #
######################
reset_sys_password () {
echo "$function_header"
echo "Started $FUNCNAME"
sys_password=$(cat $sys_password_file)
EXEC_SQL_ON_SRC "alter user sys identified by values '$sys_password';"

scp oracle@$srchost:$src_oracle_home/dbs/orapw${srcsid} /tmp/orapw${tgtsid};
scp /tmp/orapw${tgtsid} oracle@$tgthost:$tgt_oracle_home/dbs/orapw${tgtsid};
echo "Completed $FUNCNAME"
}


##################################
# rman duplicate for DB < 500 GB #
##################################
rman_duplicate () {
echo "$function_header"
echo "Started $FUNCNAME"
db_fs_count=$(ssh oracle@$tgthost "df -P $target_db_base/$tgtsid/db*|grep $target_db_base/$tgtsid/db|wc -l")
echo "db_fs_count is $db_fs_count"
if [ "$db_fs_count" -le 1  ]; then
db_file_name_convert="
 '$source_db_base/$srcsid/db001','$target_db_base/$tgtsid/db001','$source_db_base/$srcsid/db002','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db003','$target_db_base/$tgtsid/db001','$source_db_base/$srcsid/db004','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db005/','$target_db_base/$tgtsid/db001/','$source_db_base/$srcsid/db006','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db007','$target_db_base/$tgtsid/db001','$source_db_base/$srcsid/db008','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db009/','$target_db_base/$tgtsid/db001/','$source_db_base/$srcsid/db010','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db011/','$target_db_base/$tgtsid/db001/','$source_db_base/$srcsid/db012','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db013/','$target_db_base/$tgtsid/db001/','$source_db_base/$srcsid/db014','$target_db_base/$tgtsid/db001'
,'$source_db_base/$srcsid/db015','$target_db_base/$tgtsid/db001','$source_db_base/$srcsid/db016','$target_db_base/$tgtsid/db001'"
else
db_file_name_convert="'$source_db_base/$srcsid','$target_db_base/$tgtsid'"
fi
echo "db_file_name_convert is $db_file_name_convert"

ssh  oracle@$tgthost "
. /upapps/oracle/dba/scripts/pathsetup $tgtsid;
rman TARGET sys/$sys_password@${srcsid}-db1 AUXILIARY sys/$sys_password@${tgtsid}-db2 << EOF
set echo on
run{
allocate channel prmy1 type disk;
allocate channel prmy2 type disk;
allocate channel prmy3 type disk;
allocate channel prmy4 type disk;
allocate auxiliary channel stby type disk;
duplicate target database for standby from active database
SPFILE
parameter_value_convert ('$source_db_base/$srcsid','$target_db_base/$tgtsid')
set db_file_name_convert=$db_file_name_convert
set log_file_name_convert='$source_db_base/$srcsid','$target_db_base/$tgtsid'
set control_files='$target_db_base/$tgtsid/redo001/control_${tgtsid}_001.dbf','$target_db_base/$tgtsid/redo002/control_${tgtsid}_002.dbf'
set db_unique_name='$tgtdb_unique_name'
set fal_server='${srcsid}-db1'
set standby_file_management='AUTO'
set log_archive_config='dg_config=($srcdb_unique_name,$tgtdb_unique_name)'
set log_archive_dest=''
set log_archive_dest_1='location=$target_db_base/$tgtsid/archive001 valid_for=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=$tgtdb_unique_name'
set log_archive_dest_2='service=${srcsid}-db1 ASYNC valid_for=(ONLINE_LOGFILE,PRIMARY_ROLE) db_unique_name=$srcdb_unique_name'
set diagnostic_dest='$target_db_base/$tgtsid/logs'
set audit_file_dest='$target_db_base/$tgtsid/logs/audit'
#set service_names='${oracle_services}'
set utl_file_dir='$target_db_base/$tgtsid/logs, $target_db_base/$tgtsid/logs/logminer'
set sga_max_size='${target_sga}M'
set sga_target='${target_sga}M'
set use_large_pages='ONLY'
set lock_sga='FALSE'
set db_recovery_file_dest='$target_db_base/$tgtsid/fra'
set db_recovery_file_dest_size='50g'
set processes='$target_processes'
NOFILENAMECHECK;
}
exit
EOF
"
exit_code=$?
echo "rman duplicate exit_code is $exit_code"
if [ "$exit_code" -eq 0 ] ; then
        echo "rman duplicate finished without issues"
else
        echo "ERROR! rman duplicate has errors; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

#############################
# Switch logfiles on source #
#############################
switch_logfiles_on_source() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
"
echo "Completed $FUNCNAME"
}


#####################
# Save sys password #
#####################
save_sys_password() {
echo "$function_header"
echo "Started $FUNCNAME"
sys_password_file=/tmp/syspw${srcsid}.txt
if [ ! -f $sys_password_file ] ; then
  SELECT_FROM_SRC "select password from user\$ where name='SYS';"
  echo $sql_result>$sys_password_file
else
  echo  "$sys_password_file already exists"
fi
echo "Completed $FUNCNAME"
}

########################################
# Set target oratab and oramon entries #
########################################
set_oratab_oramon_entries () {
echo "$function_header"
echo "Started $FUNCNAME"
tgt_oratab_entry="$tgtsid:/software/oracle/$tgt_release_number:Y";
echo "tgt_oratab_entry=$tgt_oratab_entry"

if [ "$pord" = "p" ] ; then
  tgt_oramon_entry="$tgtsid:/software/oracle/$tgt_release_number:Y";
else
  tgt_oramon_entry="$tgtsid:/software/oracle/$tgt_release_number:N";
fi
echo "tgt_oramon_entry=$tgt_oramon_entry"

echo "Completed $FUNCNAME"
}

###############################
# Set source data guard parms #
###############################
set_source_data_guard_parms () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
alter database force logging;
alter system reset log_archive_dest;
alter system set log_archive_config='dg_config=($srcdb_unique_name,$tgtdb_unique_name)';
alter system set log_archive_dest_1='location=${source_db_base}/$srcsid/archive001 valid_for=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=$srcdb_unique_name';
alter system set log_archive_dest_2='service=${tgtsid}-db2 async valid_for=(all_logfiles,primary_role) db_unique_name=$tgtdb_unique_name';
alter system set log_archive_format='arch_${srcsid}_%t_%s_%r.dbf' scope=spfile;
alter system set standby_file_management='AUTO';
alter system set fal_server='${tgtsid}-db2';
"
echo "Completed $FUNCNAME"
}

########################
# Set target processes #
########################
set_target_processes () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select to_char(value) from v\$parameter '"where name = 'processes';"
source_processes=$sql_result
if [ "$source_processes" -lt 1000 ]; then
        target_processes=1000
else
        target_processes=$source_processes
fi
echo "target_processes is $target_processes"

echo "Completed $FUNCNAME"
}

#######################
# Set target sga size #
#######################
set_target_sga_size () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select to_char(value/1024/1024) from v\$parameter '"where name = 'sga_max_size';"
source_sga=$sql_result
target_sga=$((source_sga + 5120))
echo "Source SGA is $source_sga MB"
echo "Setting target SGA to $target_sga MB (source sga plus 5 GB)"
echo "Completed $FUNCNAME"
}

##################
# Startup target #
##################
startup_target() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT 'shutdown abort;'
ssh  oracle@$tgthost "
rm $tgt_oracle_home/dbs/init${tgtsid}.ora
echo db_name=$tgtsid>$tgt_oracle_home/dbs/init${tgtsid}.ora
echo db_domain=uprr.com>>$tgt_oracle_home/dbs/init${tgtsid}.ora
"

EXEC_SQL_ON_TGT "startup nomount pfile='$tgt_oracle_home/dbs/init${tgtsid}.ora';"
echo "Completed $FUNCNAME"
}



################
# Systemd init #
################
systemd_init() {
echo "$function_header"
echo "Started $FUNCNAME"
if ! ssh oracle@$tgthost "[ -d /oratemp/PMON_PIDS ]" ; then
  echo '/oratemp/PMON_PIDS directory does not exist on target; creating directory'
  ssh oracle@$tgthost "mkdir /oratemp/PMON_PIDS"
else
  echo 'PMON_PIDS directory already exists'
fi

echo 'Create Procedure/Directory/Trigger on source'
if [ ! -f /tmp/pmon_systemd_creation.sql ] ; then
  cat > /tmp/pmon_systemd_creation.sql << EOF
create or replace procedure UPRR_SP_LOG_PID as
OS varchar2(200);
PMON_PID number;
run_sql varchar2(200);
SID_file varchar2(200);
dir_count number;
fHandle  UTL_FILE.FILE_TYPE;
begin
sys.dbms_system.get_env('ORACLE_SID', OS) ;
dbms_output.put_line(OS);

select spid into PMON_PID from v\$process where pname = 'PMON';
select count(*) into dir_count from dba_directories where directory_name = 'PMON_DIR';
if dir_count > 0 then
SID_file := OS||'_PMON.pid';
fHandle := UTL_FILE.FOPEN('PMON_DIR', SID_file, 'w');
UTL_FILE.PUT(fHandle, PMON_PID);
UTL_FILE.FCLOSE(fHandle);
end if;
end;
/

create or replace directory pmon_dir as '/oratemp/PMON_PIDS';

create or replace trigger UPRR_TR_LOG_PID
after startup on database
begin
UPRR_SP_LOG_PID;
end;
/
EOF
fi

scp /tmp/pmon_systemd_creation.sql oracle@$srchost:/tmp/pmon_systemd_creation.sql

EXEC_SQL_ON_SRC '@/tmp/pmon_systemd_creation.sql'
echo "Completed $FUNCNAME"
}

#####################
# Test sys password #
#####################
test_sys_password () {
echo "$function_header"
echo "Started $FUNCNAME"
. /software/oracle/cli_1800_env.sh
echo "Connecting to source"
sqlplus -s sys/$sys_password@$srchost/$srcsid.uprr.com  as sysdba<< EOT
select 'OK' source from dual;
EOT
echo "Connecting to target"
sqlplus -s sys/$sys_password@$tgthost/$tgtsid.uprr.com  as sysdba<< EOT
select 'OK' target from dual;
EOT
echo "Completed $FUNCNAME"
}

#########################
# Update netadmin files #
#########################
update_netadmin_files() {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "chmod -R 775 /upapps/oracle/dba/network/admin"
ssh oracle@$tgthost "chmod -R 775 /upapps/oracle/dba/network/admin"

# both listener.ora files
listen_status=$(ssh oracle@$srchost cat /upapps/oracle/dba/network/admin/listener.ora|grep -i "SID_LIST_LISTENER"|grep -i $srcsid|wc -l);
if [ "$listen_status" -ge 1 ] ; then
  echo "listener for source already updated"
else
  echo 'Updating listener on source';
  ssh oracle@$srchost "
cd /upapps/oracle/dba/network/admin
cp listener.ora listener.ora-pre-dg
#sed -i '/USE_SID_AS_SERVICE_LISTENER/d' listener.ora
cat <<EOF >> listener.ora
SID_LIST_LISTENER=(SID_LIST=(SID_DESC=(GLOBAL_DBNAME=${srcsid}.uprr.com)(ORACLE_HOME=${oldhome})(SID_NAME=${srcsid})(UR = A)))
EOF
"
fi
listen_status=$(ssh oracle@$tgthost cat /upapps/oracle/dba/network/admin/listener.ora|grep -i "SID_LIST_LISTENER"|grep -i $tgtsid|wc -l);
if [ "$listen_status" -ge 1 ] ; then
  echo "listener for target already updated"
else
  echo 'Updating listener on target';
  ssh oracle@$tgthost "
cd /upapps/oracle/dba/network/admin
cp listener.ora listener.ora-pre-dg
cat <<EOF >> listener.ora
SID_LIST_LISTENER=(SID_LIST=(SID_DESC=(GLOBAL_DBNAME=${tgtsid}.uprr.com)(ORACLE_HOME=${tgt_oracle_home})(SID_NAME=${tgtsid})))
EOF
"
fi

# both tnsnames.ora files
if ! ssh oracle@$srchost cat /upapps/oracle/dba/network/admin/tnsnames.ora|grep -q "$srcsid-db1" ; then
  echo 'Updating tnsnames on source';
  ssh oracle@$srchost "
cd /upapps/oracle/dba/network/admin
cp tnsnames.ora tnsnames.ora-pre-dg
cat <<END >> tnsnames.ora
${srcsid}-db1.uprr.com=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${srchost})(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=${srcsid}.uprr.com)))
${tgtsid}-db2.uprr.com=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${tgthost})(PORT=1521))(CONNECT_DATA=(SERVER=dedicated)(SERVICE_NAME=${tgtsid}.uprr.com)(UR=A)))
END
"
else
  echo "tnsnames for source already updated"
fi
if ! ssh oracle@$tgthost cat /upapps/oracle/dba/network/admin/tnsnames.ora|grep -q "$tgtsid-db2" ; then
  echo 'Updating tnsnames on target';
  ssh oracle@$tgthost "
cd /upapps/oracle/dba/network/admin
cp tnsnames.ora tnsnames.ora-pre-dg
cat <<END >> tnsnames.ora
${srcsid}-db1.uprr.com=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${srchost})(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=${srcsid}.uprr.com)))
${tgtsid}-db2.uprr.com=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${tgthost})(PORT=1521))(CONNECT_DATA=(SERVER=dedicated)(SERVICE_NAME=${tgtsid}.uprr.com)(UR=A)))
END
"
else
  echo "tnsnames for target already updated"
fi

# target sqlnet.ora file is updated in 4_upgrade_target.sh update_sqlnet_file function


ssh oracle@$srchost "chmod -R 555 /upapps/oracle/dba/network/admin"
ssh oracle@$tgthost "chmod -R 555 /upapps/oracle/dba/network/admin"
echo "Completed $FUNCNAME"
}

#################################
# Validate listeners are stable #
#################################
validate_listeners_are_stable() {
echo "$function_header"
echo "Started $FUNCNAME"
listener_status=$(ssh oracle@$srchost ". /upapps/oracle/dba/scripts/pathsetup $srcsid; lsnrctl stat|grep $srcsid|grep READY|wc -l") ;
listener_timeout=$((SECONDS+60));
while [ "$listener_status" -lt 1 -a "$SECONDS" -lt "$listener_timeout" ] ; do
  sleep 5;
  listener_status=$(ssh oracle@$srchost ". /upapps/oracle/dba/scripts/pathsetup $srcsid; lsnrctl stat|grep $srcsid|grep READY|wc -l") ;
  echo "Waiting on $srchost $srcsid"
done
if [ "$SECONDS" -ge "$listener_timeout" ] ; then
  echo "ERROR! Waiting for $srcsid on $srchost timed out; exiting";
  exit 1
else
  ssh oracle@$srchost ". /upapps/oracle/dba/scripts/pathsetup $srcsid; lsnrctl stat|grep $srcsid|grep READY" ;
fi

listener_status=$(ssh oracle@$tgthost ". /upapps/oracle/dba/scripts/pathsetup $tgtsid; lsnrctl stat|grep $tgtsid|grep UNKNOWN|wc -l") ;
listener_timeout=$((SECONDS+60));
while [ "$listener_status" -lt 1 -a "$SECONDS" -lt "$listener_timeout" ] ; do
  sleep 5;
  listener_status=$(ssh oracle@$tgthost ". /upapps/oracle/dba/scripts/pathsetup $tgtsid; lsnrctl stat|grep $tgtsid|grep UNKNOWN|wc -l") ;
  echo "Waiting on $tgthost $tgtsid"
done
if [ "$SECONDS" -ge "$listener_timeout" ] ; then
  echo "ERROR! Waiting for $tgtsid on $tgthost timed out; exiting";
  exit 1
else
  ssh oracle@$tgthost ". /upapps/oracle/dba/scripts/pathsetup +ASM; lsnrctl stat|grep $tgtsid|grep UNKNOWN" ;
fi
echo "Completed $FUNCNAME"
}

MAIN="main"

[ $# -lt 1  ] && { echo "Missing Arguments! Usage: $0 <srcsid>"; exit 1; }
srcsid=$1

. source/project_functions.sh

GET_PARMS
logdir="/logs/dte/$project_name/$tgtsid/$tgthost"
if [ ! -d $logdir ]; then
  mkdir -p $logdir
fi

logfile="$logdir/${script_name}_${tgtsid}_${srchost}_${tgthost}.log"
[ -z "$TYPESCRIPT" ] && TYPESCRIPT=1 exec /usr/bin/script -c "TYPESCRIPT=1  $0 $*" -e $logfile

STARTUP
check_environment

<<COMMENT
COMMENT


###############################
# read only actions on source #
###############################
check_source_archivelog_count
backup_source_pfile

#####################
# actions on target #
#####################
copy_gold_bash_profile_to_target
add_target_oratab_oramon
copy_password_file_to_target
copy_wallet_to_target
create_target_db_base_directories

################################
# actions on source and target #
################################
backup_listener_and_tnsnames_files
update_netadmin_files
reload_listeners
validate_listeners_are_stable


############################
# update actions on source #
############################
prep_source_for_data_guard
systemd_init
enable_java


set_target_sga_size
set_target_processes
startup_target
test_sys_password
disable_remove_archived_logs
rman_duplicate


finalize_instantiation
reset_sys_password
reload_listeners
switch_logfiles_on_source

<<COMMENT
COMMENT

WRAP_UP
