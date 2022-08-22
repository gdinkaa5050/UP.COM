#!/bin/bash

dg_message="
col host format a20
col message format a80
select d.name, substr(i.host_name,1,20) host, facility, severity, dest_id, error_code, callout, to_char(timestamp, 'HH24:MI:SS') TIME, substr(message,1,80) message
from v\$database d
    ,v\$instance i
    ,v\$dataguard_status
where timestamp > sysdate - 5/(24*60) order by message_num;
"

dg_status_logical_standby="
col host           format a20
col realtime_apply format a15
col state          format a20
col applied_scn    format 999999999999999999
col newest_scn     format 999999999999999999
select d.name, substr(i.host_name,1,20) host, d.open_mode, d.database_role, d.switchover_status,
  sb.realtime_apply, sb.state, e.txn_errors,
  p.applied_scn, to_char(p.applied_time,'mon-dd hh24:mi:ss') applied_time,
  p.newest_scn, to_char(p.newest_time,'mon-dd hh24:mi:ss') newest_time
from v\$database d
  ,v\$instance i
  ,v\$logstdby_state sb
  ,dba_logstdby_progress p
  ,(select count(*) txn_errors from dba_logstdby_events
    where event_time = (select max(event_time) from dba_logstdby_events) and xidusn is not null) e;
"

dg_status_primary="
col host format a20
col destination format a15
col error format a20
select * from
(
select d.name, substr(i.host_name,1,20) host, d.open_mode, d.database_role, d.switchover_status
from v\$database d
    ,v\$instance i
) left outer join
(
select a.thread#,b.dest_id,a.sequence# LATEST ,b.sequence# APPLIED, a.sequence# - b.sequence# NOT_APPLIED from
(
select dest_id,thread#,max(sequence#) sequence# from v\$archived_log
where dest_id in (select to_number(ltrim(name,'log_archive_dest_')) from v\$parameter where lower(name) like 'log_archive_dest%' and upper(value) like '%SERVICE=%'
minus
select dest_id from v\$archive_dest where VALID_ROLE  in ('STANDBY_ROLE'))
 and applied='YES' group by dest_id,thread#) b,
(select thread#,max(sequence#) sequence#  from v\$archived_log where activation# in (select activation# from v\$database) group by thread#) a
where a.thread#=b.thread#
and 'PRIMARY' =(select database_role from v\$database)
union
select b.dest_id,a.thread#,a.sequence# LATEST ,b.sequence# APPLIED, a.sequence# - b.sequence# NOT_APPLIED from
(select dest_id,thread#,max(sequence#) sequence# from v\$archived_log where applied='YES' and  dest_id in ( select dest_id from v\$archive_dest where destination is not null and upper(VALID_ROLE) in ('ALL_ROLES','STANDBY_ROLE') and dest_id <> 32 ) group by dest_id,thread#) b,
(select thread#,max(sequence#) sequence#  from v\$archived_log where activation# in (select activation# from v\$database) group by thread#) a
where a.thread#=b.thread#
and 'PHYSICAL STANDBY' =(select database_role from v\$database)
) on 1=1 left outer join
(
select destination, target, schedule, process, gvad.status, error
from gv\$archive_dest gvad, gv\$instance gvi
where gvad.inst_id = gvi.inst_id and dest_id=2
order by thread#, dest_id
) on 1=1;
"

sql_dg_status_physical="
col host format a20
select d.name, substr(i.host_name,1,20) host, d.open_mode, d.database_role, d.switchover_status, lr.thread, lr.max_seq_rcvd, la.thread, la.max_seq_appl, m.process, d.database_role
from v\$database d
    ,v\$instance i
    left outer join
      (select thread# thread, max(sequence#) max_seq_rcvd from v\$archived_log
       --where first_time > sysdate-2/24
       where resetlogs_id = 1059161796
       group by thread# ) lr on 1=1
    left outer join
      (select thread# thread, max(sequence#) max_seq_appl from v\$log_history
       where first_time > sysdate-1/24
       --where resetlogs_change# = 1059161796
       group by thread#) la on 1=1
    left outer join (select process process from v\$managed_standby where process like 'MR%') m on 1=1;
"








redo_apply_rate() {
echo '### redo_apply_rate'
ssh oracle@$tgthost "
export ORACLE_SID=$tgtsid;
export ORAENV_ASK=NO;
source oraenv -s;
export ORAENV_ASK=YES;
sqlplus -s / as sysdba << 'EOT'
select to_char(start_time, 'HH24:MI:SS') start_time, item, round(sofar/1024,2) MB_Per_Second
from v\$recovery_progress
where (item='Active Apply Rate' or item='Average Apply Rate');
EOT
"
}

current_scn() {
echo '### current_scn'
ssh oracle@$srchost "
export ORACLE_SID=$srcsid;
export ORAENV_ASK=NO;
source oraenv -s;
export ORAENV_ASK=YES;
sqlplus -s / as sysdba << 'EOT'
set numwidth 20
select current_scn from v\$database;
EOT
"
}

recovery_progress() {
echo '### recovery_progress'
ssh oracle@$tgthost "
export ORACLE_SID=$tgtsid;
export ORAENV_ASK=NO;
source oraenv -s;
export ORAENV_ASK=YES;
sqlplus -s / as sysdba << 'EOT'
set lines 1000
select item, units, sofar, total, timestamp from v\$recovery_progress;
EOT
"
}

missing_archive_logs() {
echo '### missing_archive_logs'
ssh oracle@$tgthost "
export ORACLE_SID=$tgtsid;
export ORAENV_ASK=NO;
source oraenv -s;
export ORAENV_ASK=YES;
sqlplus -s / as sysdba << 'EOT'
SELECT THREAD#, LOW_SEQUENCE#, HIGH_SEQUENCE# FROM V\$ARCHIVE_GAP;
EOT
"
}

MAIN="main"

[ $# -ne 2  ] && { echo "Missing Arguments! Usage: $0 <srcsid>"; exit 1; }
srcsid=$1
sleep_time=$2

. source/project_functions.sh

GET_PARMS

while [ 0 -ne 1 ]; do
SELECT_FROM_SRC 'select database_role from v\$database;'
src_database_role=$sql_result
clear
SELECT_FROM_TGT 'select database_role from v\$database;'
tgt_database_role=$sql_result
clear


if [ "$src_database_role" = "PRIMARY" ] ; then
  REPORT_FROM_SRC "$dg_status_primary"
else
  REPORT_FROM_SRC "$dg_status_logical_standby"
fi
REPORT_FROM_SRC "$dg_message"



if [ "$tgt_database_role" = "PRIMARY" ] ; then
  REPORT_FROM_TGT "$dg_status_primary"
else
  REPORT_FROM_TGT "$dg_status_logical_standby"
fi
REPORT_FROM_TGT "$dg_message"




#redo_apply_rate
#current_scn
#recovery_progress
#missing_archive_logs


sleep $sleep_time
done
