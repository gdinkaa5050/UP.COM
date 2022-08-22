#!/bin/bash

###################################
# Add target supplemental logging #
###################################
add_target_supplemental_logging() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter database add supplemental log data (primary key, unique index) columns;"
echo "Completed $FUNCNAME"
}

#####################
# Alter target open #
#####################
alter_target_open() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
alter database open;
alter trigger SYS.DSA_TR_CHEK_OS_AUTH disable;
"
get_standby_status
echo "Completed $FUNCNAME"
}


#########################################
# Build LogMiner Metadata for SQL Apply #
#########################################
build_source_logminer_metadata () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "execute dbms_logstdby.build;"
echo "Completed $FUNCNAME"
}

###############################
# Cancel log apply on standby #
###############################
cancel_target_log_apply () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter database recover managed standby database cancel;"
echo "Completed $FUNCNAME"
}

#####################################
# Convert target to logical standby #
#####################################
convert_target_to_logical_standby() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT '
alter database recover to logical standby keep identity;
select switchover_status, '"'NOT ALLOWED'"' should_be from v\$database;
select database_role, '"'LOGICAL STANDBY'"' should_be from v\$database;
'
echo "Completed $FUNCNAME"
}

###################
# Pre upgrade jar #
###################
pre_upgrade_jar() {
echo "$function_header"
echo "Started $FUNCNAME"

EXEC_SQL_ON_TGT 'drop role EM_EXPRESS_BASIC;'

ssh oracle@$tgthost "
#mv ${tgt_oracle_home}/sqlplus/admin/glogin.sql ${tgt_oracle_home}/sqlplus/admin/glogin.sql.current
#mv ${upg_oracle_home}/sqlplus/admin/glogin.sql ${upg_oracle_home}/sqlplus/admin/glogin.sql.current

. /upapps/oracle/dba/scripts/pathsetup ${tgtsid}
${tgt_oracle_home}/jdk/bin/java -jar ${upg_oracle_home}/rdbms/admin/preupgrade.jar FILE TEXT
"

EXEC_SQL_ON_TGT "@/software/oracle/cfgtoollogs/$tgtdb_unique_name/preupgrade/preupgrade_fixups.sql"
echo "Completed $FUNCNAME"
}

#####################
# Pre upgrade stats #
#####################
pre_upgrade_stats() {
echo "$function_header"
echo "Started $FUNCNAME"
scp timezone/countstatsTSTZ.sql oracle@${tgthost}.uprr.com:/tmp
scp timezone/countstarTSTZ.sql oracle@${tgthost}.uprr.com:/tmp

EXEC_SQL_ON_TGT "
--@/tmp/countstatsTSTZ.sql
--@/tmp/countstarTSTZ.sql

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

################################
# Restart target in mount mode #
################################
restart_target_in_mount_mode () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
shutdown immediate;
startup mount;
"
echo "Completed $FUNCNAME"
}

######################################
# Setup source db_recovery_file_dest #
######################################
set_source_db_recovery_file_dest() {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "mkdir -p /logs/oracle/${srcsid}/flashback"
EXEC_SQL_ON_SRC "
alter system set db_recovery_file_dest_size=5G scope=both sid='*';
alter system set db_recovery_file_dest='/logs/oracle/${srcsid}/flashback' scope=both sid='*';
"
echo "Completed $FUNCNAME"
}

########################
# Set target processes #
########################
set_target_processes() {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select value from v\$parameter '"where name='processes';"
processes=$sql_result
echo "processes = $processes"

SELECT_FROM_SRC 'select value from v\$parameter '"where name='parallel_max_servers';"
parallel_max_servers=$sql_result
echo "parallel_max_servers = $parallel_max_servers"

temp_value=$((parallel_max_servers + 100))
if [ $processes -gt $temp_value ]; then
  processes=$processes
else
  processes=$temp_value
fi
echo "Setting target processes to $processes"
EXEC_SQL_ON_SRC "alter system set processes=${processes} scope=spfile;"
echo "Completed $FUNCNAME"
}

################################
# Set target standby logs dest #
################################
set_target_standby_logs_dest() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
alter system set log_archive_dest_3='location=/oratemp/${tgtsid}/standby_archive001 valid_for=(STANDBY_LOGFILES,STANDBY_ROLE) db_unique_name=$tgtdb_unique_name';
"
echo "Completed $FUNCNAME"
}


#####################################
# Validate No Unsupported Datatypes #
#####################################
validate_no_unsupported_datatypes() {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "
select to_char(count(*)) from dba_logstdby_not_unique where (owner,table_name) not in
(select distinct owner, table_name from dba_logstdby_unsupported) and bad_column='Y';
"
unsupported_count=$sql_result
if [ $unsupported_count -gt 0 ] ; then
  echo 'Please check the following unsupported datatypes before proceeding:'
  REPORT_FROM_SRC "
select * from dba_logstdby_not_unique where (owner,table_name) not in
(select distinct owner, table_name from dba_logstdby_unsupported) and bad_column='Y';
"
  echo "Log Apply services will attempt to maintain these tables. Do you want to proceed?  Enter y or n, followed by [ENTER]"
  #read proceed
  #if [ $proceed = "y" ]; then
    echo 'Proceeding'
  #else
  #  echo 'Exiting'
  #  exit 1
  #fi
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

<<COMMENT
COMMENT


##########################
# prepare for conversion #
##########################
set_source_db_recovery_file_dest
set_target_processes
validate_no_unsupported_datatypes
cancel_target_log_apply
build_source_logminer_metadata
add_target_supplemental_logging

##############################
# convert to logical standby #
##############################
convert_target_to_logical_standby
restart_target_in_mount_mode
set_target_standby_logs_dest
alter_target_open
configure_standby_sql_apply
setup_standby_event_logging
start_standby_sql_apply
validate_standby_realtime_apply
validate_standby_state


<<COMMENT
COMMENT

WRAP_UP
