#!/bin/bash

##################
# Alter scn parm #
##################
alter_scn_parm() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT '
alter system set "_external_scn_rejection_threshold_hours" = 66000 scope=both;
'
echo "Completed $FUNCNAME"
}

################################
# Comment source oratab oramon #
################################
comment_source_oratab_oramon () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "
echo "oratab before and after"
grep -e $srcsid /etc/oratab
sed  \"s/^${srcsid}/#${srcsid}/\" /etc/oratab > /tmp/oratab
cat /tmp/oratab > /etc/oratab
grep -e $srcsid /etc/oratab

echo "oramon before and after"
grep -e $srcsid /software/oracle/oramon
sed  \"s/^${srcsid}/#${srcsid}/\" /software/oracle/oramon > /tmp/oratab
cat /tmp/oratab > /software/oracle/oramon
grep -e $srcsid /software/oracle/oramon
"
echo "Completed $FUNCNAME"
}


#################################
# Confirm source is now standby #
#################################
confirm_source_is_now_standby () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
col guard_status format a12
select version,database_role,open_mode,guard_status
 "'from v\$database, v\$instance'"
left outer join
(select process from "'gv\$managed_standby'" where process like 'MRP%') on 1=1
;
"
echo "CONFIRM source Database role:     LOGICAL STANDBY"
echo "CONFIRM source Open mode:         READ WRITE"
echo "CONFIRM source Guard status:      ALL"
echo
press_enter_to_proceed
echo "Completed $FUNCNAME"
}

#################################
# Confirm target is now primary #
#################################
confirm_target_is_now_primary () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
col guard_status format a12
select version,database_role,open_mode,guard_status
 "'from v\$database, v\$instance'"
left outer join
(select recovery_mode, gap_status from "'v\$archive_dest_status'" where dest_id=4) on 1=1
;
"
echo "CONFIRM target Database role:     PRIMARY"
echo "CONFIRM target Open mode:         READ WRITE"
echo "CONFIRM source Guard status:      NONE"
echo
press_enter_to_proceed
echo "Completed $FUNCNAME"
}

###############################
# Create source restore point #
###############################
create_source_restore_point () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "mkdir /logs/oracle/${srcsid}/flashback"
EXEC_SQL_ON_SRC "
alter system set db_recovery_file_dest_size=20G scope=both sid='*';
alter system set db_recovery_file_dest='/logs/oracle/${srcsid}/flashback' scope=both sid='*';
"

EXEC_SQL_ON_SRC "create restore point PRE_FLIP guarantee flashback database;"
SELECT_FROM_SRC "select name "'from v\$restore_point'";"
restore_name=$sql_result
if [ "$restore_name" != "PRE_FLIP" ]; then
        echo "ERROR! Restore point not created; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}
#################################
# Determine primary and standby #
#################################
determine_primary_and_standby() {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select database_role from v\$database;'
database_role1=$sql_result

SELECT_FROM_TGT 'select database_role from v\$database;'
database_role2=$sql_result

if  [ "$database_role1" = "PRIMARY" ] && [ "$database_role2" = "LOGICAL STANDBY" ] ; then
  srcsid=$1
  srchost=$2
  tgtsid=$3
  tgthost=$4
elif [ "$database_role2" = "PRIMARY" ] && [ "$database_role1" = "LOGICAL STANDBY" ] ; then
  srcsid=$3
  srchost=$4
  tgtsid=$1
  tgthost=$2
else
  echo 'ERROR! Primary and Standby servers not specified correctly; exiting'
  exit 1
fi
echo "Source sid  is $srcsid"
echo "Source host is $srchost"
echo "Target sid  is $tgtsid"
echo "Target host is $tgthost"
echo "Completed $FUNCNAME"
}

#############################
# Disable target dataguard #
#############################
disable_target_dataguard() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
set serveroutput on size unlimited
declare
  alter_ddl varchar2(100);
begin
for parm in
( select name from "'v\$parameter'"
  where name in
    ('db_file_name_convert',
    'fal_server',
    'log_archive_config',
    'log_archive_dest_2',
    'log_file_name_convert',
    'standby_file_management' )
  and value is not null
)
loop
 alter_ddl := 'alter system reset '||parm.name||' scope=spfile';
 dbms_output.put_line(alter_ddl);
 execute immediate alter_ddl;
end loop;
end;
/
shutdown immediate;
startup;
"
echo "Completed $FUNCNAME"
}


############################
# drop_target_standby_logs #
############################
drop_target_standby_logs () {
echo "$function_header"
echo "Started $FUNCNAME"
remove_standby_logs_file="/tmp/remove_standby_logs_$srcsid.sh"
SELECT_FROM_TGT "
spool $remove_standby_logs_file
select 'rm '||member||';' from "'v\$logfile'" where type= upper('standby');
"
EXEC_SQL_ON_TGT "
set serveroutput on size unlimited
declare
  alter_ddl varchar2(100);
begin
for file in
( select group# from "'v\$standby_log'" )
loop
 alter_ddl := 'alter database drop standby logfile group '||file.group#;
 dbms_output.put_line(alter_ddl);
 execute immediate alter_ddl;
end loop;
end;
/
"
ssh oracle@$tgthost "
chmod 775 $remove_standby_logs_file
$remove_standby_logs_file
"
echo "Completed $FUNCNAME"
}

#####################
# Get target status #
#####################
get_target_stat () {
#echo "$function_header"
#echo "Started $FUNCNAME"
SELECT_FROM_TGT "select switchover_status "'from v\$database;'
tgt_status=$sql_result
echo "Completed $FUNCNAME"
};

######################################
# Flip cname to point to new primary #
######################################
flip_cname () {
echo "$function_header"
echo "Started $FUNCNAME"
#/upapps/dte/oracle-administrative-scripts/v1.0/cname_utility.sh ${tgtsid} ${tgthost} ${tgtsid} update
list_cnames="ssh dfrf001@failover.dea.tla.uprr.com /software/frf/oraclefarm/bin/farmutil cname --list --sid $tgtsid"
update_cnames="ssh dfrf001@failover.dea.tla.uprr.com /software/frf/oraclefarm/bin/farmutil cname --update-all $tgtsid --target $tgthost"
echo $list_cnames
$list_cnames

echo $update_cnames
$update_cnames

echo $list_cnames
$list_cnames
echo "Completed $FUNCNAME"
}

############################
# reset log_archive_dest_3 #
############################
reset_log_archive_dest_3 () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter system reset log_archive_dest_3 scope=both;"
ssh oracle@$tgthost rm -rf "/oratemp/$tgtsid/standby_archive001"
echo "Completed $FUNCNAME"
}

########################################
# restart target with new dbs location #
########################################
restart_target_with_new_dbs_location () {
echo "$function_header"
echo "Started $FUNCNAME"

ssh oracle@$tgthost "
cd ${upg_oracle_home}/dbs
if [ -f init${tgtsid}.ora ]; then
  mv init${tgtsid}.ora ${target_db_base}/${tgtsid}/dbs
  ln -s ${target_db_base}/${tgtsid}/dbs/init${tgtsid}.ora init${tgtsid}.ora
fi

if [ -f spfile${tgtsid}.ora ]; then
  mv spfile${tgtsid}.ora ${target_db_base}/${tgtsid}/dbs
  ln -s ${target_db_base}/${tgtsid}/dbs/spfile${tgtsid}.ora spfile${tgtsid}.ora
fi

if [ -f orapw${tgtsid}  ]; then
  mv orapw${tgtsid} ${target_db_base}/${tgtsid}/dbs
  ln -s ${target_db_base}/${tgtsid}/dbs/orapw${tgtsid} orapw${tgtsid}
fi
"
EXEC_SQL_ON_TGT "
shutdown immediate;
startup;
"
echo "Completed $FUNCNAME"
}

##########################
# Restore netadmin files #
##########################
restore_netadmin_files () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "
chmod -R 775 /upapps/oracle/dba/network/admin
cd /upapps/oracle/dba/network/admin
mv listener.ora-pre-dg listener.ora
mv tnsnames.ora-pre-dg tnsnames.ora
chmod -R 555 /upapps/oracle/dba/network/admin
"
ssh oracle@$tgthost "
chmod -R 775 /upapps/oracle/dba/network/admin
cd /upapps/oracle/dba/network/admin
mv listener.ora-pre-dg listener.ora
mv tnsnames.ora-pre-dg tnsnames.ora
mv sqlnet.ora-pre-dg sqlnet.ora
chmod -R 555 /upapps/oracle/dba/network/admin
"
echo "Completed $FUNCNAME"
}

############################
# Shutdown Source Database #
############################
shutdown_source_db () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "shutdown immediate;"
echo "Completed $FUNCNAME"
}

############################
# Shutdown Target Database #
############################
shutdown_target_db () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "shutdown immediate;"
echo "Completed $FUNCNAME"
}

###############
# Signoff scp #
###############
signoff_scp () {
echo "$function_header"
echo "Started $FUNCNAME"
echo "scp_nbr is $scp_nbr"
echo "tgtsid is $tgtsid"
ssh dfrf001@failover.dea.tla.uprr.com /software/frf/oraclefarm/bin/farmutil scp --sign-off --proj $scp_nbr --sid $tgtsid
echo "Completed $FUNCNAME"
}

##########################
# Switch primary logfile #
##########################
switch_source_logfiles () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
"
echo 'Sleeping for 1 minute to allow dataguard apply to catch up'
sleep 1m
echo "Completed $FUNCNAME"
}

#############################
# Switch primary to standby #
#############################
switch_primary_to_standby () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "alter database commit to switchover to logical standby;"
echo "Completed $FUNCNAME"
}

#############################
# Switch standby to primary #
#############################
switch_standby_to_primary () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter database commit to switchover to primary;"
echo "Completed $FUNCNAME"
}

##########################
# Switch target logfiles #
##########################
switch_target_logfile () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
"
echo "Completed $FUNCNAME"
}

###########################
# Update migration status #
###########################
update_migration_status () {
echo "$function_header"
echo "Started $FUNCNAME"
host=prod138.oracle
sid=prod138
EXEC_SQL "
update prd_inst set cmnt='Sourced from $srcsid on '||trunc(sysdate) where type||inst_nbr = '$pdb';
update PRD_MIGR_19C set actl_migr_date=trunc(sysdate), outg_mins=$outage_minutes where src_sid = '$srcsid';
"
echo "Completed $FUNCNAME"
}

#############################
# Update logminer procedure #
#############################
update_logminer_procedure () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
create or replace procedure sys.lgmr_sp_crat_dict as
filename varchar2(30);
dayofweek varchar2(9);
runday    varchar2(9);
obj_chng  number(8);
begin
    -- load up variables
    runday := 'saturday';
    select  rtrim(to_char(sysdate,'day'))
        into dayofweek from dual;
    select count(*)
        into obj_chng from dba_objects
        where trunc(created) > trunc(sysdate) - 2;
    select 'logminer_'||lower(name)||'_'||to_char(sysdate,'yyyymmdd')||'.ora'
         into filename from v\$database;
     if dayofweek = runday or obj_chng > 0 then
        dbms_logmnr_d.build(filename,'logmnr_output');

     end if;
end;
/
"
echo "Completed $FUNCNAME"
}

################################
# Update target db directories #
################################
update_target_db_directories () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
create or replace directory free_space_dir as '${target_db_base}/$tgtsid/logs/free_space_dir';
grant read, write on directory free_space_dir to dma_read;
grant read, write on directory free_space_dir to dmon900;
create or replace directory locking_dir as '${target_db_base}/$tgtsid/logs/lock_file_dir';
grant read on directory locking_dir to dma_read;
create or replace directory logmnr_output as '${target_db_base}/$tgtsid/logs/logminer';
create or replace directory wllt_dir as '/software/oracle/admin/$tgtdb_unique_name/wallet';
create or replace directory data_pump_dir as '${target_db_base}/$tgtsid/dpdump';
drop directory oracle_ocm_config_dir;
drop directory oracle_ocm_config_dir2;
"
echo "Completed $FUNCNAME"
}




#############################
# Update logminer procedure #
#############################
update_logmnr_procedure () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
create or replace procedure sys.lgmr_sp_crat_dict as
filename varchar2(30);
dayofweek varchar2(9);
runday    varchar2(9);
obj_chng  number(8);
begin
    -- load up variables
    runday := 'saturday';
    select  rtrim(to_char(sysdate,'day'))
        into dayofweek from dual;
    select count(*)
        into obj_chng from dba_objects
        where trunc(created) > trunc(sysdate) - 2;
    select 'logminer_'||lower(name)||'_'||to_char(sysdate,'yyyymmdd')||'.ora'
         into filename from v\$database;
     if dayofweek = runday or obj_chng > 0 then
        dbms_logmnr_d.build(filename,'logmnr_output');

     end if;
end;
/
"
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

<<COMMENT
COMMENT

create_source_restore_point
switch_source_logfiles
outage_start_time=$(date)

check_primary_switchover_status
switch_primary_to_standby
check_standby_switchover_status
switch_standby_to_primary

confirm_target_is_now_primary
confirm_source_is_now_standby


switch_target_logfile
disable_target_dataguard
drop_target_standby_logs
restart_target_with_new_dbs_location
flip_cname
outage_seconds=$(($(date "+%s")-$(date -d "$outage_start_time" "+%s")))
outage_minutes=$(($outage_seconds/60))

shutdown_source_db
comment_source_oratab_oramon


update_target_db_directories
#update_logminer_procedure
alter_scn_parm
#create_logs_dir
restore_netadmin_files
update_migration_status
reset_log_archive_dest_3
signoff_scp

<<COMMENT
COMMENT

WRAP_UP
