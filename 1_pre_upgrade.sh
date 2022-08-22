#!/bin/bash

################################
# Alter source compatible parm #
################################
alter_source_compatible_parm () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
alter system set compatible='11.2.0' scope=spfile;
shutdown immediate;
startup;
"
echo "Completed $FUNCNAME"
}

##############################
# Check not null no validate #
##############################
check_not_null_no_validate () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "
select to_char(count(1))
from sys.col$ a, sys.ecol$ b, sys.obj$ c, sys.user$ u
where a.obj#=b.tabobj#
and a.intcol#=b.colnum
and a.obj#=c.obj#
and c.owner# = u.user#
and a.property=1073741824
and a.null$=0
;
"
if [[ ! $sql_result == "0" ]] ; then
        echo "ERROR; found not null no validate issues; see MOS Doc ID 2017572.1; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

##################################
# Check remote os authentication #
##################################
check_remote_os_authentication () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "
select to_char(count(1))
from DBA_AUDIT_TRAIL
where username like 'OPS$%'
and userhost not in (select host_name "'from v\$instance'")
and timestamp > sysdate - 30
;
"
if [[ ! $sql_result == "0" ]] ; then
        echo "WARNING! Using remote os authentication"
fi
echo "Completed $FUNCNAME"
}

#########################################
# Check source and target listener link #
#########################################
check_source_and_target_listener_links () {
echo "$function_header"
echo "Started $FUNCNAME"
if ssh oracle@$tgthost "[ -L /software/oracle/listener ]" ; then
  echo 'Listener link on target exists'
else
  echo 'Listener link on target does not exist; creating link'
  ssh oracle@$tgthost "
  #. /software/oracle/$tgt_env_sh
  cd /software/oracle/$tgt_release_number/network/admin
  ln -s /upapps/oracle/dba/network/admin/tnsnames.ora tnsnames.ora
  ln -s /upapps/oracle/dba/network/admin/listener.ora listener.ora
  ln -s /upapps/oracle/dba/network/admin/sqlnet.ora sqlnet.ora
  cd /software/oracle
  ln -s /software/oracle/$tgt_release_number listener
  "
fi

if ssh oracle@$tgthost "[ -L /software/oracle/listener ]" ; then
        echo 'Listener link on source exists'
else
        echo 'ERROR! Listener link on source does not exists; exiting'
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

################################
# Check source archivelog mode #
################################
check_source_archivelog_mode () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select log_mode from v\$database;'
echo "Database is in $sql_result mode"
if [ ! $sql_result = "ARCHIVELOG" ] ; then
        if [ "$pord" = "p" ]; then
                echo "Logarchive is not enabled. Do you want to enable it now?  Enter y or n, followed by [ENTER]"
                read proceed
                if [ $proceed = "y" ]; then
                        enable_archivelog
                else
                        echo "Exiting"
                        exit_code=1; EMAIL_DBA; exit $exit_code
                fi
        else
                enable_archivelog
        fi
else
        echo "Archivelog enabled"
fi
echo "Completed $FUNCNAME"
}

################################
# Check source compatible parm #
################################
check_source_compatible_parm () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "select value "'from v\$parameter'" where name='compatible';"
echo "Oracle compatible parm is $sql_result"
if [[ $sql_result = "10"* || $sql_result = "11.1"* ]]; then
        if [ "$pord" = "p" ]; then
                echo "Exiting"
                exit_code=1; EMAIL_DBA; exit $exit_code
        else
                echo "Altering compatible"
                alter_source_compatible_parm
        fi
fi
echo "Completed $FUNCNAME"
}

###############################################
# Check source_datafile_are_in_db_directories #
###############################################
check_source_datafiles_are_in_db_directories () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select to_char(count(*)) result from v\$datafile '"where substr(substr(name,instr(name,'/',-1,2)+1),1,instr(substr(name,instr(name,'/',-1,2)+1),'/')-3) not like 'db0%';"

echo "$sql_result datafiles not following db0% format"
if [ $sql_result -ne 0  ] ; then
        echo "ERROR! Datafile not in db directory; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

#####################################
# Check source for auto memory mgmt #
#####################################
check_source_for_auto_memory_mgmt () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select to_char(count(*)) from v\$parameter '"where name = 'memory_target' and value !='0';"
amm_count=$sql_result
if [ $amm_count = 0 ] ; then
        echo "Source is not using AMM"
else
        echo "ERROR! Source is using AMM; switch to ASMM before migrating; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

#############################################
# Check source for duplicate datafile names #
#############################################
check_source_for_duplicate_datafile_names () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "select to_char(count(substr(name,instr(name,'/',-1)+1)) - count(distinct substr(name,instr(name,'/',-1)+1))) from "'v\$datafile;'
if [ $sql_result -eq 0 ] ; then
        echo "No duplicate datafile names"
else
        echo "ERROR! $sql_result duplicate datafile name(s) found; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

##########################################
# Check source file systems less than 17 #
##########################################
check_source_file_systems_less_than_17 () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "select to_char(round(sum(bytes)/1024/1024/1024)) from dba_data_files;"
if [ $sql_result -lt 500  ] ; then
        SELECT_FROM_SRC "select to_char(count(distinct(substr(substr(name,instr(name,'/',-1,2)+1),1,instr(substr(name,instr(name,'/',-1,2)+1),'/')-1)))) "'from v\$datafile;'
        echo "$sql_result Database mount points"
        if [ $sql_result -gt 16  ] ; then
                echo "ERROR! Number of mounts > 16 and database < 500GB; exiting"
                exit_code=1; EMAIL_DBA; exit $exit_code
        fi
else
        echo "Database > 500GB; No of filesystems irrelevant"
fi
echo "Completed $FUNCNAME"
}

###############################
# Check source Oracle version #
###############################
check_source_oracle_version () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC 'select version from v\$instance;'
if [[ $sql_result = *"$src_version"* ]]; then
        echo "Oracle version $sql_result on $srchost is correct"
else
        echo "Expected Oracle version $src_version; found $sql_result; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code;
fi
echo "Completed $FUNCNAME"
}

###################################
# check target file systems exist #
###################################
check_target_fs_exist () {
echo "$function_header"
echo "Started $FUNCNAME"
for dir in archive001 db001 redo001 redo002
do
        fs_count=$(ssh oracle@$tgthost "df -P $target_db_base/$tgtsid/$dir|grep -v Filesystem|wc -l")
        if [ "$fs_count" -eq 1 ] ; then
                echo "$target_db_base/$tgtsid/$dir is mounted"
        else
                echo "ERROR! $target_db_base/$tgtsid/$dir is not mounted; exiting"
                exit_code=1; EMAIL_DBA; exit $exit_code
        fi
done
echo "Completed $FUNCNAME"
}

#################################################
# check target file systems greater_than_source #
#################################################
check_target_fs_greater_than_source_used () {
echo "$function_header"
echo "Started $FUNCNAME"
source_fs_used=$(ssh oracle@$srchost df -mP $source_db_base/$srcsid/db* |grep -v Filesystem | awk '{used_mb += $3} END {print used_mb}')
echo "source_fs_used is $source_fs_used MB"

target_fs_size=$(ssh oracle@$tgthost df -mP $target_db_base/$tgtsid/db* |grep -v Filesystem | awk '{size_mb += $2} END {print size_mb}')
echo "target_fs_size is $target_fs_size MB"

if [ "$target_fs_size" -lt "$source_fs_used" ] ; then
        echo "ERROR! Target file systems are less than source file systems; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

#################################
# Check target listener started #
#################################
check_target_listener_started () {
echo "$function_header"
echo "Started $FUNCNAME"
listener_count=$( ssh oracle@$tgthost ps aux | grep "[t]nslsnr" | wc -l );
if [[ $listener_count = 0 ]] ; then
  echo 'Target listener not started; starting listener';
  ssh oracle@$tgthost "/upapps/oracle/dba/scripts/listener start;";
else
  echo 'Target listener already started'
fi
echo "Completed $FUNCNAME"
}

###################################
# Check target oracle home exists #
###################################
check_target_oracle_home_exists () {
echo "$function_header"
echo "Started $FUNCNAME"
if ssh oracle@$tgthost "[ -d $tgt_oracle_home ]" ; then
        echo "$tgt_oracle_home exists on target"
else
        echo "ERROR! $tgt_oracle_home does not exist on target; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
if ssh oracle@$tgthost "[ -d $upg_oracle_home ]" ; then
        echo "$upg_oracle_home exists on target"
else
        echo "ERROR! $upg_oracle_home does not exist on target; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

###########################
# Check target os version #
###########################
check_target_os_version () {
echo "$function_header"
echo "Started $FUNCNAME"
os_version=$(ssh oracle@$tgthost grep ^VERSION= /etc/os-release)
if [[ "$os_version" =  *"7.9"* ]]; then
        echo "os_version is $os_version"
else
        echo "ERROR! Expected OS version 7.9; found $os_version; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

###############################
# Confirm oracle home patched #
###############################
confirm_oracle_home_patched () {
echo "$function_header"
echo "Started $FUNCNAME"
if ! ssh oracle@$tgthost test -d $upg_oracle_home/bin ; then
        echo "ERROR! Oracle home not installed; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
lspatches=$(ssh oracle@$tgthost $upg_oracle_home/OPatch/opatch lspatches -oh $upg_oracle_home)
echo "lspatches is $lspatches"
if [[ "$lspatches" =  *"33541736"* ]]; then
        echo "Oracle home is patched"
else
        echo "Oracle home is NOT patched"
        if [ "$pord" = "p" ]; then
                echo "Patching Oracle software requires ALL databases using $upg_oracle_home to be shutdown"
                echo "Do you want to proceed? Enter y or n, followed by [ENTER]"
                read proceed
                if [ $proceed = "y" ]; then
                        patch_oracle_home
                else
                        echo "ERROR! Oracle home not patched; exiting"
                        exit_code=1; EMAIL_DBA; exit $exit_code
                fi
        else
                patch_oracle_home
        fi
fi

echo "Completed $FUNCNAME"
}

########################
# Confirm source db up #
########################
confirm_source_db_up () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "select 'source db is up' from dual;"
if [ "$sql_result" != "source db is up" ] ; then
        echo "ERROR! Source database is down; check logs; exiting"
        exit_code=1; EMAIL_DBA; exit $exit_code
fi
echo "Completed $FUNCNAME"
}

#####################
# Enable archivelog #
#####################
enable_archivelog () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
alter system reset log_archive_dest scope=spfile;
alter system set log_archive_dest_1='location=$source_db_base/$srcsid/archive001' scope=spfile;
alter system set log_archive_format='arch_$sid_%t_%s_%r.dbf' scope=spfile;
shutdown immediate;
startup mount;
alter database archivelog;
alter database open;
archive log list;
alter system switch logfile;
alter system switch logfile;
alter system switch logfile;
"
echo "Completed $FUNCNAME"
}

####################
# mos health check #
####################
mos_health_check () {
echo "$function_header"
echo "Started $FUNCNAME"
scp downloads/hcheck.sql oracle@$srchost:/software/oracle/tmp
EXEC_SQL_ON_SRC "@/software/oracle/tmp/hcheck.sql"
echo "Completed $FUNCNAME"
}

#####################
# Patch oracle home #
#####################
patch_oracle_home () {
echo "$function_header"
echo "Started $FUNCNAME"
cd $base_dir/db-patch/stand-alone/$upg_release_number
./patch_database.sh $tgthost
cd -
echo "Completed $FUNCNAME"
}

###################
# Pre upgrade jar #
###################
pre_upgrade_jar () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC 'drop role EM_EXPRESS_BASIC;'
scp downloads/preupgrade.jar oracle@$srchost:/software/oracle/tmp
ssh oracle@$srchost "
. /upapps/oracle/dba/scripts/pathsetup ${tgtsid}
${src_oracle_home}/jdk/bin/java -jar /software/oracle/tmp/preupgrade.jar FILE TEXT
exit $?
"
exit_code=$?
echo "preupgrade exit_code is $exit_code"
if [ $exit_code -ne 0 ]; then
        echo "ERROR! Check preupgrade; exiting"
        EMAIL_DBA; exit $exit_code
fi
EXEC_SQL_ON_SRC "@/software/oracle/cfgtoollogs/${srcdb_unique_name}/preupgrade/preupgrade_fixups.sql"
exit_code=$?
echo "preupgrade_fixups exit_code is $exit_code"
if [ $exit_code -ne 0 ]; then
        echo "ERROR! Check preupgrade_fixups; exiting"
        EMAIL_DBA; exit $exit_code
fi
echo "Note: the ORACLE_RESERVED_USERS and the TWO_PC_TXN_EXIST errors will be fixed on the target database"
echo "Completed $FUNCNAME"
}

######################################
# Setup source db recovery file dest #
######################################
setup_source_db_recovery_file_dest () {
echo "$function_header"
echo "Started $FUNCNAME"
SELECT_FROM_SRC "select value "'from v\$parameter'" where name = 'log_archive_dest_1';"
echo "log_archive_dest_1 is $sql_result"
if [ -z "$sql_result" ] ; then
        if [ "$pord" = "p" ]; then
                echo "log_archive_dest_1 is not set. Do you want to update it now?  Enter y or n, followed by [ENTER]"
                read proceed
                if [ $proceed = "y" ]; then
                        update_log_archive_dest_1
                else
                        echo "Exiting"
                        exit_code=1; EMAIL_DBA; exit $exit_code
                fi
        else
                update_log_archive_dest_1
        fi
fi

echo "Completed $FUNCNAME"
}

############################
# Update eat pre-migration #
############################
update_eat_pre_migration () {
echo "$function_header"
echo "Started $FUNCNAME"

if [[ "$tgtsid" = "xtst"* || "$tgtsid" = "prod"*  ]]; then
        tgt_type=${tgtsid:0:4}
        tgt_inst_nbr=${tgtsid:4}
else
        tgt_type=${tgtsid:0:3}
        tgt_inst_nbr=${tgtsid:3}
fi
echo "tgt_type     is $tgt_type"
echo "tgt_inst_nbr is $tgt_inst_nbr"
host=prod138.oracle
sid=prod138
EXEC_SQL "
update prd_inst set cmnt='Target for $srcsid' where type||inst_nbr = '$pdb';
insert into prd_inst_appl (type, inst_nbr, appl_name, scma_ownr)
select '$tgt_type', '$tgt_inst_nbr', appl_name, scma_ownr from prd_inst_appl
where type||inst_nbr  = '$srcsid';
commit;
"
REPORT_FROM_OTHER "
col scma_ownr format a20
select type||inst_nbr instance, appl_name, scma_ownr from prd_inst_appl
where type||inst_nbr  in ( '$pdb', '$srcsid');
"
echo "Completed $FUNCNAME"
}


#############################
# Update log archive dest 1 #
#############################
update_log_archive_dest_1 () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
alter system reset log_archive_dest scope=spfile;
alter system set log_archive_dest_1='location=$source_db_base/$srcsid/archive001' scope=spfile;
alter system set log_archive_format='arch_$sid_%t_%s_%r.dbf' scope=spfile;
shutdown immediate;
startup ;
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
[ -z "$TYPESCRIPT" ] && TYPESCRIPT=1 exec /usr/bin/script -c "TYPESCRIPT=1 $0 $*" -e $logfile

STARTUP

<<COMMENT
COMMENT


confirm_oracle_home_patched
check_source_oracle_version
check_source_for_auto_memory_mgmt
check_source_and_target_listener_links
check_source_archivelog_mode
setup_source_db_recovery_file_dest
pre_upgrade_jar
mos_health_check

check_target_os_version
check_target_oracle_home_exists
if [ "$srchost" != "$tgthost" ]; then
        check_source_for_duplicate_datafile_names
        check_source_file_systems_less_than_17
        check_source_datafiles_are_in_db_directories
        check_target_listener_started
        check_target_fs_exist
        check_target_fs_greater_than_source_used
fi
confirm_source_db_up
check_not_null_no_validate
check_remote_os_authentication
check_source_compatible_parm
update_eat_pre_migration


<<COMMENT
COMMENT

WRAP_UP
