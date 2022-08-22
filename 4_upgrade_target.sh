#!/bin/bash

###################
# Apply dst patch #
###################
apply_dst_patch () {
echo "$function_header"
echo "Started $FUNCNAME"

echo "UPDATE THIS FUNCTION"

echo "Completed $FUNCNAME"
}

################################
# Alter target compatible parm #
################################
alter_target_compatible_parm () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
alter system set compatible='11.2.0' scope=spfile;
shutdown immediate;
startup;
"
echo "Completed $FUNCNAME"
}

##################
# Check listener #
##################
check_listener () {
echo "$function_header"
echo "Started $FUNCNAME"
if ssh oracle@$tgthost "[ -L /software/oracle/listener ]" ; then
        echo "Listener link exists"
        listener_version=$(ssh oracle@$tgthost readlink -f /software/oracle/listener|cut -d/ -f4)
        if [ "$listener_version" != "$upg_release_number" ]; then
                restart_target_listener
        fi
else
        echo "ERROR! listener link doesn't exist; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "/software/oracle/listener => $(ssh oracle@$tgthost readlink -f /software/oracle/listener)"
echo "Running listener is $(ssh oracle@$tgthost ps -ef |grep -v grep | grep tnslsnr)"
echo "Completed $FUNCNAME"
}

################################
# Check target compatible parm #
################################
check_target_compatible_parm () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_TGT "select value "'from v\$parameter'" where name='compatible';"
echo "Oracle compatible parm is $sql_result"
if [[ $sql_result = "10"* || $sql_result = "11.1"* ]]; then
        echo "Altering compatible"
        alter_target_compatible_parm
        SELECT_FROM_TGT "select value "'from v\$parameter'" where name='compatible';"
        echo "Oracle compatible parm is $sql_result"
        if [[ ! $sql_result = "11.2"* ]]; then
                echo "ERROR! compatible not updated; exiting"
                exit_code=1; EMAIL_DBA; exit $exit_code
        fi
fi
echo "Completed $FUNCNAME"
}

#########################################
# Copy password file to new oracle home #
#########################################
copy_password_file_to_new_oracle_home () {
echo "$function_header"
echo "Started $FUNCNAME"
scp oracle@$srchost:$src_oracle_home/dbs/orapw${srcsid} /tmp/orapw${tgtsid};
scp /tmp/orapw${tgtsid} oracle@$tgthost:$upg_oracle_home/dbs/orapw${tgtsid};
echo "Completed $FUNCNAME"
}

###################################
# Create target restore point #
###################################
create_target_restore_point () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "mkdir /logs/oracle/${tgtsid}/flashback"
EXEC_SQL_ON_TGT "
alter system set db_recovery_file_dest_size=40G scope=both sid='*';
alter system set db_recovery_file_dest='/logs/oracle/${tgtsid}/flashback' scope=both sid='*';
"

EXEC_SQL_ON_TGT "create restore point PRE_UPGRADE guarantee flashback database;"
SELECT_FROM_TGT "select name "'from v\$restore_point'";"
restore_name=$sql_result
if [ "$restore_name" != "PRE_UPGRADE" ]; then
        echo "ERROR! Restore point not created; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}


##############################
# Create upgrade config file #
##############################
create_auto_upgrade_config_file () {
echo "$function_header"
echo "Started $FUNCNAME"
config_dir="/logs/oracle/logs/upgrade/$tgtsid"
ssh oracle@$tgthost "mkdir -p $config_dir"
config_file="auto_upgrade.cfg"
echo "config_dir/config_file  is $config_dir/$config_file"
ssh oracle@$tgthost "
cat <<EOF >  $config_dir/$config_file
global.autoupg_log_dir=/logs/oracle/logs/upgrade
global.target_version=19
global.target_home=$upg_oracle_home
#global.remove_underscore_parameters=yes

upg1.dbname=$tgtsid
upg1.sid=$tgtsid
upg1.log_dir=/logs/oracle/logs/upgrade
upg1.upgrade_node=${tgthost}.uprr.com
upg1.source_home=$tgt_oracle_home
upg1.start_time=NOW
upg1.run_utlrp=yes
upg1.timezone_upg=yes

#upg1.restoration=no
#upg1.drop_grp_after_upgrade=yes
EOF
"
echo "Completed $FUNCNAME"
}

#################
# CREATE SPFILE #
#################
create_spfile () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "create spfile from pfile;"
ssh oracle@$tgthost "
cd $upg_oracle_home/dbs
mv init${srcsid}.ora init${srcsid}.ora-backup
"
restart_target_database
echo "Completed $FUNCNAME"
}

##############
# Fix wallet #
##############
fix_wallet () {
echo "$function_header"
echo "Started $FUNCNAME"
if ssh oracle@$tgthost "[ -d /software/oracle/admin/$tgtdb_unique_name/wallet ]" ; then
        EXEC_SQL_ON_TGT "
alter system set tde_configuration='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;
exec dbms_scheduler.set_job_argument_value (job_name => 'wllt_chek_job',argument_position => 1,argument_value => '/software/oracle/admin/$tgtdb_unique_name/wallet/tde');
--drop directory LOCKING_DIR;
--create directory LOCKING_DIR as '/oradata/$tgtdb/logs/lock_file_dir';
alter table uprr_wllt_chek modify (location varchar2(100));
exec dbms_scheduler.run_job('wllt_chek_job');
set linesize 300
col comments format a20
select * from sys.uprr_wllt_chek;
"
fi

echo "Completed $FUNCNAME"
}

#########################
# Enable autotask stats #
#########################
enable_autotask_stats () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
begin
    dbms_auto_task_admin.enable(client_name => 'auto optimizer stats collection',operation => NULL,window_name => NULL);
end;
/
"
EXEC_SQL_ON_TGT "
begin
for job in
( select distinct job_name from dba_scheduler_jobs where job_name like 'GATHER_STATS%'
)
loop
    begin
      dbms_scheduler.drop_job (job_name => job.job_name,force => false);
    end;
end loop;
end;
/
"
EXEC_SQL_ON_TGT "
begin
for job in
( select distinct job job_nbr from dba_jobs where lower(what) like '%uprr_analyze%'
)
loop
    begin
      dbms_job.remove(job.job_nbr);
    end;
end loop;
end;
/
"
EXEC_SQL_ON_TGT "exec dbms_auto_task_immediate.gather_optimizer_stats;"
echo "Completed $FUNCNAME"
}

#######################
# Expire sys password #
#######################
expire_sys_password () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
alter user sys password expire;
alter user sys identified by W6Jru3jRf6hJ2eP;
"
echo "Completed $FUNCNAME"
}


#####################
# Pre upgrade fixes #
#####################
pre_upgrade_fixes () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter system set "\""_system_trig_enabled"\""=false;"
EXEC_SQL_ON_TGT "drop trigger sys.dsa_tr_chek_os_auth;
"

EXEC_SQL_ON_TGT "
set serveroutput on size unlimited
begin
for tran in
(select local_tran_id from sys.dba_2pc_pending
order by 1
)
loop
     dbms_output.put_line('purge local_tran_id: '||tran.local_tran_id);
     begin
        dbms_transaction.purge_lost_db_entry(tran.local_tran_id);
     exception
        when others then dbms_output.put_line(sqlerrm);
     end;
end loop;
end;
/
"
echo "Completed $FUNCNAME"
}

###################
# Pre upgrade jar #
###################
pre_upgrade_jar () {
echo "$function_header"
echo "Started $FUNCNAME"

EXEC_SQL_ON_TGT 'drop role EM_EXPRESS_BASIC;'

ssh oracle@$tgthost "
#mv ${tgt_oracle_home}/sqlplus/admin/glogin.sql ${tgt_oracle_home}/sqlplus/admin/glogin.sql.current
#mv ${upg_oracle_home}/sqlplus/admin/glogin.sql ${upg_oracle_home}/sqlplus/admin/glogin.sql.current

. /upapps/oracle/dba/scripts/pathsetup ${tgtsid}
${tgt_oracle_home}/jdk/bin/java -jar ${upg_oracle_home}/rdbms/admin/preupgrade.jar FILE TEXT
exit $?
"
exit_code=$?
echo "preupgrade exit_code is $exit_code"
if [ $exit_code -ne 0 ]; then
        echo "ERROR! Check preupgrade; exiting"
        EMAIL_DBA; exit $exit_code
fi
EXEC_SQL_ON_TGT "@/software/oracle/cfgtoollogs/$tgtdb_unique_name/preupgrade/preupgrade_fixups.sql"
echo "Completed $FUNCNAME"
}

#####################
# Pre upgrade stats #
#####################
pre_upgrade_stats () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
purge dba_recyclebin;

exec dbms_stats.gather_dictionary_stats;
exec dbms_stats.gather_fixed_objects_stats;

exec dbms_stats.gather_schema_stats('SYS');
exec dbms_stats.gather_index_stats('SYS','I_OBJ#');
exec dbms_stats.gather_index_stats('SYS','I_FILE#_BLOCK#');
exec dbms_stats.gather_index_stats('SYS','I_TS#');
exec dbms_stats.gather_index_stats('SYS','I_USER#');
exec dbms_stats.gather_index_stats('SYS','I_TOID_VERSION#');
exec dbms_stats.gather_index_stats('SYS','I_MLOG#');
exec dbms_stats.gather_index_stats('SYS','I_RG#');
"'
select dbms_stats.get_stats_history_availability from dual;
select dbms_stats.get_stats_history_retention from dual;
exec dbms_stats.alter_stats_history_retention(7);
select dbms_stats.get_stats_history_retention from dual;
select systimestamp - dbms_stats.get_stats_history_availability from dual;
select count(*) from SYS.WRI\$_OPTSTAT_HISTGRM_HISTORY;
select count(*) from SYS.WRI\$_OPTSTAT_HISTHEAD_HISTORY;
exec dbms_scheduler.purge_log;
exec dbms_stats.purge_stats(dbms_stats.purge_all);
exec dbms_stats.purge_stats(systimestamp);
exec dbms_stats.purge_stats(sysdate-7);
select count(*) from SYS.WRI\$_OPTSTAT_HISTGRM_HISTORY;
select count(*) from SYS.WRI\$_OPTSTAT_HISTHEAD_HISTORY;
'
echo "Completed $FUNCNAME"
}

############################
# Run auto upgrade analyze #
############################
run_auto_upgrade_analyze () {
echo "$function_header"
echo "Started $FUNCNAME"
jar_dir="/software/oracle/tmp"
if ! ssh oracle@$tgthost test -f ${jar_dir}/autoupgrade.jar ; then
        scp autoupgrade.jar oracle@$tgthost:${jar_dir}
else
        echo "${jar_dir}/autoupgrade.jar already exists"
fi
ssh oracle@$tgthost "$upg_oracle_home/jdk/bin/java -jar $jar_dir/autoupgrade.jar -config $config_dir/$config_file -mode analyze"
last_job=$( ssh oracle@$tgthost "cd $config_dir; ls -tr|tail -1" )
echo "last_job is $last_job"
ssh oracle@$tgthost "cat $config_dir/$last_job/autoupgrade_err.log"
echo "Note: the ORACLE_RESERVED_USERS and the TWO_PC_TXN_EXIST errors will be fixed on the target database for dataguard migrations"
echo "Completed $FUNCNAME"
}

############################
# Recreate temp tablespace #
############################
recreate_temp_tablespace () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_TGT "select property_value from database_properties where property_name = 'DEFAULT_TEMP_TABLESPACE';"
temp_tablespace=$sql_result
echo "temp_tablespace is $temp_tablespace"
if [[ $temp_tablespace == "TMPTSL00"* ]]; then
        echo "temp tablespace has already been moved"
        EXEC_SQL_ON_TGT "
alter database default temporary tablespace $temp_tablespace;
drop tablespace TMPTS001 including contents and datafiles;
"
else
        SELECT_FROM_TGT "select to_char(round(sum(bytes/1024/1024/1024))) from dba_temp_files where tablespace_name = '$temp_tablespace';"
        current_temp_gb=$sql_result
        echo "current_temp_gb is $current_temp_gb"ccc
        SELECT_FROM_TGT 'select to_char(value) from v\$parameter '"where name='db_block_size';"
        blocksize=$sql_result
        if [ $blocksize -eq 8192 ] ; then
                min_temp_gb=16
        else
                min_temp_gb=8
        fi
        echo "min_temp_gb is $min_temp_gb"
        if [ $current_temp_gb -gt 30 ] ; then
                echo 'Creating temp tablespace with multiple files'
                # Find out how many 30GB temp files needed; Round Up
                file_size=30
                number_of_files=$(bc <<< "scale=2;$temp_size/$file_size")
                number_of_files=`echo $number_of_files | awk '{print ($0-int($0)>0)?int($0)+1:int($0)}'`
                echo "number_of_files is $number_of_files"

                # Create new tablespace with initial file
                EXEC_SQL_ON_TGT "create temporary tablespace tmptsl001 tempfile '/oratemp/tmptsl001_${tgtsid}_001.dbf' size 30g;"
                # Loop and add necessary tempfiles
                for (( i=2; i<=$number_of_files; i++ ))
                        do
                                EXEC_SQL_ON_TGT "alter tablespace tmptsl001 add tempfile '/oratemp/tmptsl001_${tgtsid}_00${i}.dbf' size 30g;"
                        done
        else
                if [ $current_temp_gb -lt $min_temp_gb ] ; then
                        current_temp_gb=$min_temp_gb
                fi
                EXEC_SQL_ON_TGT "create temporary tablespace tmptsl001 tempfile '/oratemp/tmptsl001_${tgtsid}_001.dbf' size $current_temp_gb g;"
        fi

        EXEC_SQL_ON_TGT "
alter database default temporary tablespace tmptsl001;
--shutdown immediate;
--startup;
drop tablespace $temp_tablespace including contents and datafiles;
"
fi
echo "Completed $FUNCNAME"
}

###########################
# Restart target database #
###########################
restart_target_database() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
shutdown immediate;
startup;
"
echo "Completed $FUNCNAME"
}

###########################
# Restart target listener #
###########################
restart_target_listener () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "
. /upapps/oracle/dba/scripts/pathsetup ${tgtsid};
/software/oracle/listener/bin/lsnrctl stop

cd $upg_oracle_home/network/admin
pwd
rm tnsnames.ora; ln -s /upapps/oracle/dba/network/admin/tnsnames.ora tnsnames.ora
rm listener.ora; ln -s /upapps/oracle/dba/network/admin/listener.ora listener.ora
rm sqlnet.ora;   ln -s /upapps/oracle/dba/network/admin/sqlnet.ora sqlnet.ora
ls -l *ora
cd /software/oracle
pwd
rm listener; ln -s $upg_oracle_home listener
ls -l listener

/software/oracle/listener/bin/lsnrctl start
"
echo "Completed $FUNCNAME"
}


##################
# Deploy upgrade #
##################
run_auto_upgrade_deploy () {
echo "$function_header"
echo "Started $FUNCNAME"
config_dir="/logs/oracle/logs/upgrade/$tgtsid"
config_file="auto_upgrade.cfg"
jar_dir="/software/oracle/tmp"
echo "To monitor upgrade:"
echo "cd /logs/oracle/logs/upgrade/$tgtsid/<job_no>"
echo "tail -f autoupgrade_$(date '+%Y%m%d')_user.log"
ssh oracle@$tgthost "$upg_oracle_home/jdk/bin/java -jar $jar_dir/autoupgrade.jar -config $config_dir/$config_file -mode deploy"
last_job=$( ssh oracle@$tgthost "cd $config_dir; ls -tr|tail -1" )
echo "last_job is $last_job"
if ssh oracle@$tgthost test -s  $config_dir/$last_job/autoupgrade_err.log ; then
  ssh oracle@$tgthost "cat $config_dir/$last_job/autoupgrade_err.log"
else
  echo "No auto upgrade errors"
fi
echo "Completed $FUNCNAME"
}

####################
# Run post upgrade #
####################
run_post_upgrade () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_TGT "select comments "'from registry\$history'" where action='BOOTSTRAP';"
registry_comment=$sql_result
if [ "$registry_comment" = "RDBMS_19.9.0.0.0DBRU_LINUX.X64_200930" ]; then
        echo "Database has been successfully upgraded to $upg_release_number"
        echo "Dropping the restore point"
        EXEC_SQL_ON_TGT "drop restore point PRE_UPGRADE;"
        EXEC_SQL_ON_TGT "alter system reset db_recovery_file_dest scope=both;"
else
        echo "Database is not at version $upg_release_number; review upgrade logs"
        echo "Restore point NOT dropped; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi

EXEC_SQL_ON_TGT '
alter system set "_exclude_seed_cdb_view" = false scope=both;
alter system set "_cursor_obsolete_threshold" = 1024 scope=spfile;
alter system set "_enable_space_preallocation" = 0 scope=both;
'
EXEC_SQL_ON_TGT "
execute dbms_optim_bundle.enable_optim_fixes('on','both', 'yes');
grant select on "'user\$'" to dmon900;
"
EXEC_SQL_ON_TGT "
prompt Remove Multimedia
@\${ORACLE_HOME}/rdbms/admin/catcmprm.sql ORDIM
Y
drop package sys.ordimdpcallouts;
"
EXEC_SQL_ON_TGT "
prompt Post-Upgrade Status Tool
@\${ORACLE_HOME}/rdbms/admin/utlusts.sql none

set lines 300 pages 5000
col COMP_NAME for a40
col COMP_ID   for a9
col VERSION   for a12
col STATUS    for a12
select comp_id,comp_name,version,status from dba_registry order by 1;
"
EXEC_SQL_ON_TGT "
begin
for job in (select job nbr from dba_jobs where what like '%coalesce_indexes%' or lower(what) like '%dsa_os_auth_wtch%')
loop
  dbms_job.remove(job.nbr);
end loop;
end;
/
"
update_oracle_services_parm
restart_target_database
#ssh oracle@$tgthost "
#mv ${tgt_oracle_home}/sqlplus/admin/glogin.sql.current ${tgt_oracle_home}/sqlplus/admin/glogin.sql
#mv ${upg_oracle_home}/sqlplus/admin/glogin.sql.current ${upg_oracle_home}/sqlplus/admin/glogin.sql
#"

EXEC_SQL_ON_TGT "alter system set compatible = '19.0.0' scope=spfile;"
EXEC_SQL_ON_TGT "alter system set wallet_root='/software/oracle/admin/$tgtdb_unique_name/wallet' scope=spfile;"

restart_target_database
recreate_temp_tablespace
enable_autotask_stats
fix_wallet
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
update PRD_MIGR_19C set actl_migr_date=trunc(sysdate), outg_mins=$outage_minutes where src_sid = '$srcsid';
"
echo "Completed $FUNCNAME"
}

#################################
# Update spfile with min values #
#################################
update_target_db_with_min_values () {
echo "$function_header"
echo "Started $FUNCNAME"
echo "Completed $FUNCNAME"
SELECT_FROM_TGT 'select to_char(value) from v\$parameter '"where name = 'processes';"
target_processes=$sql_result
echo "target_processes is $target_processes"
if [ "$target_processes" -lt 1000 ]; then
        EXEC_SQL_ON_TGT "alter system set processes=1000 scope=spfile;"
        restart_target_database
fi

SELECT_FROM_TGT 'select to_char(value/1024/1024) from v\$parameter '"where name = 'sga_max_size';"
target_sga_max_size=$sql_result
echo "target_sga_max_size is $target_sga_max_size MB"
if [ "$target_sga_max_size" -lt 5008 ]; then
        EXEC_ON_TGT "alter system set sga_max_size=5008m scope=spfile;"
        EXEC_ON_TGT "alter system set sga_target=5008m scope=spfile;"
else
EXEC_ON_TGT "alter system set sga_target=${target_sga_max_size}m scope=spfile;"
fi
restart_target_database

echo "Completed $FUNCNAME"
}

######################
# Update sqlnet file #
######################
update_sqlnet_file () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "chmod -R 775 /upapps/oracle/dba/network/admin"
ssh oracle@$tgthost "chmod -R 775 /upapps/oracle/dba/network/admin"
for sqlnet_parm in SQLNET.ALLOWED_LOGON_VERSION_SERVER=8 SQLNET.ALLOWED_LOGON_VERSION_CLIENT=8 SQLNET.ALLOWED_LOGON_VERSION=8; do
if ! ssh oracle@$tgthost cat /upapps/oracle/dba/network/admin/sqlnet.ora|grep -q "$sqlnet_parm" ; then
  ssh oracle@$tgthost "
cd /upapps/oracle/dba/network/admin
cat <<END >> sqlnet.ora
$sqlnet_parm
END
"
fi
done
ssh oracle@$tgthost cat /upapps/oracle/dba/network/admin/sqlnet.ora
ssh oracle@$srchost "chmod -R 555 /upapps/oracle/dba/network/admin"
ssh oracle@$tgthost "chmod -R 555 /upapps/oracle/dba/network/admin"
echo "Completed $FUNCNAME"
}

#####################
# Upgrade target db #
#####################
upgrade_target_db () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "
. /upapps/oracle/dba/scripts/pathsetup ${tgtsid}
export SQLPATH=''
export ORACLE_HOME=$upg_oracle_home
cd \${ORACLE_HOME}/bin
pwd
./dbua -silent -sid ${tgtsid} -oracleHome ${tgt_oracle_home} -upgrade_parallelism 2 -upgradeTimezone true -emConfiguration NONE
echo exit code is $?
"
exit_code=$?
echo "upgrade exit_code is $exit_code"
if [ $exit_code -ne 0 ]; then
        echo "ERROR! Check upgrade; exiting"
        EMAIL_DBA; exit $exit_code
fi
EXEC_SQL_ON_TGT "
@/software/oracle/cfgtoollogs/$tgtdb_unique_name/preupgrade/postupgrade_fixups.sql
"
EXEC_SQL_ON_TGT "
set lines 1000
set pages 1000
set pause off
@?/rdbms/admin/utlrp.sql
"
echo "Completed $FUNCNAME"
}

#####################
# Upgrade timezones #
#####################
upgrade_timezones () {
echo "$function_header"
echo "Started $FUNCNAME"
apply_dst_patch
timezone_dir="/software/oracle/tmp/timezone"
ssh oracle@$tgthost "mkdir $timezone_dir"
scp DBMS_DST_scriptsV1.9/* $tgthost:$timezone_dir
EXEC_SQL_ON_TGT "
@$timezone_dir/countstatsTSTZ.sql
@$timezone_dir/upg_tzv_check.sql
@$timezone_dir/upg_tzv_apply.sql
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

[ "$srchost" != "$tgthost" ] && stop_standby_sql_apply

check_target_compatible_parm
pre_upgrade_stats
pre_upgrade_jar
#       stage_auto_upgrade_jar                          add function
#       create_auto_upgrade_config_file
#       run_auto_upgrade_analyze

pre_upgrade_fixes
create_target_restore_point
[ "$srchost" = "$tgthost" ] && outage_start_time=$(date)
update_target_db_with_min_values
upgrade_target_db

#       upgrade_timezones                       # only run if running auto upgrade
#       run_auto_upgrade_deploy

copy_password_file_to_new_oracle_home
create_spfile
run_post_upgrade
[ "$srchost" = "$tgthost" ] && outage_seconds=$(($(date "+%s")-$(date -d "$outage_start_time" "+%s")))
[ "$srchost" = "$tgthost" ] && outage_minutes=$(($outage_seconds/60))


[ "$srchost" != "$tgthost" ] && start_standby_sql_apply
[ "$srchost" != "$tgthost" ] && validate_standby_state


# [ "$src_version" = "11.2.0.4" ] && update_sqlnet_file
update_sqlnet_file

check_listener
enable_remove_archived_logs
[ "$srchost" = "$tgthost" ] && update_migration_status

<<COMMENT
COMMENT

WRAP_UP
