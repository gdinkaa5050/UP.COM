#!/bin/bash

#######################
# Archive log current #
#######################
archive_log_current() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "alter system archive log current;"
echo "Completed $FUNCNAME"
}

#######################
# Create rman catalog #
#######################
create_rman_catalog() {
echo "$function_header"
echo "Started $FUNCNAME"
if [ "$pord" == "d" ] ; then
 rman_instance='po47'
else
 rman_instance='po46'
fi

ssh oracle@$srchost "
. /upapps/oracle/dba/scripts/pathsetup $srcsid;
rman << 'EOT'
connect catalog rman_$tgtsid/oscar@$rman_instance
create catalog;
connect target /
register database;
exit
EOT
"
echo "Completed $FUNCNAME"
}

#############################
# Disable source data guard #
#############################
disable_source_data_guard () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "
set serveroutput on size unlimited
declare
  alter_ddl varchar2(100);
begin
for parm in
( select name from "'v\$parameter'"
  where name in
    ('db_recovery_file_dest',
    'fal_server',
    'log_archive_config',
    'log_archive_dest_2' )
  and value is not null
)
loop
 alter_ddl := 'alter system set '||parm.name||'=''''';
 dbms_output.put_line(alter_ddl);
 execute immediate alter_ddl;
end loop;
end;
/
"
EXEC_SQL_ON_SRC "
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
)
loop
 alter_ddl := 'alter system reset '||parm.name;
 dbms_output.put_line(alter_ddl);
 execute immediate alter_ddl;
end loop;
end;
/
"
<<COMMENT
EXEC_SQL_ON_SRC "
shutdown immediate;
startup;
"
COMMENT
echo "Completed $FUNCNAME"
}

#####################
# Drop rman catalog #
#####################
drop_rman_catalog() {
echo "$function_header"
echo "Started $FUNCNAME"
if [ "$pord" == "d" ] ; then
 rman_instance='po47'
else
 rman_instance='po46'
fi

ssh oracle@$tgthost "
. /upapps/oracle/dba/scripts/pathsetup $srcsid;
rman << 'EOT'
connect catalog rman_$tgtsid/oscar@$rman_instance
drop catalog;
drop catalog;
exit;
EOT
"
echo "Completed $FUNCNAME"
}

###########################
# Drop source archivelogs #
###########################
drop_source_restore_point() {
echo "$function_header"
echo "Started $FUNCNAME"

EXEC_SQL_ON_SRC "
set serveroutput on size unlimited
declare
  alter_ddl varchar2(100);
begin
for restore in
( select name from "'v\$restore_point'" )
loop
 alter_ddl := 'drop restore point  '||restore.name;
 dbms_output.put_line(alter_ddl);
 execute immediate alter_ddl;
end loop;
end;
/
"
echo "Completed $FUNCNAME"
}

############################
# drop_source_standby_logs #
############################
drop_source_standby_logs() {
echo "$function_header"
echo "Started $FUNCNAME"
remove_standby_logs_file="/tmp/remove_standby_logs_$srcsid.sh"
SELECT_FROM_SRC "
spool $remove_standby_logs_file
select 'rm '||member||';' from "'v\$logfile'" where type= upper('standby');
"
EXEC_SQL_ON_SRC "
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
ssh oracle@$srchost "
chmod 775 $remove_standby_logs_file
$remove_standby_logs_file
"
echo "Completed $FUNCNAME"
}

###########################
# Drop target archivelogs #
###########################
drop_target_archivelogs () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "rm /oradata/$tgtsid/archive001/*"
echo "Completed $FUNCNAME"
}

########################
# Drop target database #
########################
drop_target_database() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
shutdown abort;
startup mount exclusive restrict;
drop database;
"
echo "Completed $FUNCNAME"
}

###################################
# Flashback source to pre upgrade #
###################################
flashback_source_to_pre_upgrade () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "
sed '/^$srcsid/s/$upg_release_number/$src_release_number/' /etc/oratab > /tmp/oratab
cat /tmp/oratab > /etc/oratab
"
EXEC_SQL_ON_SRC "
shutdown immediate;
startup mount;
flashback database to restore point PRE_UPGRADE;
alter database open resetlogs;
drop restore point PRE_UPGRADE;
"
echo "Completed $FUNCNAME"
}

###########################
# Remove target dbs files #
###########################
remove_target_dbs_files() {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "
rm ${tgt_oracle_home}/dbs/*${tgtsid}*
rm ${upg_oracle_home}/dbs/*${tgtsid}*
"
echo "Completed $FUNCNAME"
}

##########################
# Remove target from crs #
##########################
remove_target_from_crs() {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "
. /upapps/oracle/dba/scripts/pathsetup +ASM;
srvctl remove database -db $tgtdb_unique_name -noprompt
"
echo "Completed $FUNCNAME"
}

###############################
# Remove target oratab oramon #
###############################
remove_target_oratab_oramon() {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "
grep -v $tgtsid /etc/oratab > /tmp/oratab
cat /tmp/oratab > /etc/oratab
grep -e $tgtsid /etc/oratab

grep -v $tgtsid /software/oracle/oramon > /tmp/oramon
cat /tmp/oramon > /software/oracle/oramon
grep -e $tgtsid /software/oracle/oramon
"
echo "Completed $FUNCNAME"
}

###############################
# Remove target oratemp files #
###############################
remove_target_oratemp_files () {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$tgthost "rm -rf /oratemp/$tgtsid/*"
echo "Completed $FUNCNAME"
}

############################
# Remove tpm password file #
############################
remove_tpm_password_file() {
echo "$function_header"
echo "Started $FUNCNAME"
rm /tmp/syspw${tgtsid}.txt
echo "Completed $FUNCNAME"
}

##################################
# Uncomment source oratab oramon #
##################################
uncomment_source_oratab_oramon() {
echo "$function_header"
echo "Started $FUNCNAME"
ssh oracle@$srchost "
echo "oratab before and after"
grep -e $srcsid /etc/oratab
sed  \"s/^#${srcsid}/${srcsid}/\" /etc/oratab > /tmp/oratab
cat /tmp/oratab > /etc/oratab
grep -e $srcsid /etc/oratab

echo "oramon before and after"
grep -e $srcsid /software/oracle/oramon
sed  \"s/^#${srcsid}/${srcsid}/\" /software/oracle/oramon > /tmp/oratab
cat /tmp/oratab > /software/oracle/oramon
grep -e $srcsid /software/oracle/oramon
"
echo "Completed $FUNCNAME"
}

#########################
# Update netadmin files #
#########################
update_net_admin_files() {
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

if [ "$srchost" = "$tgthost" ] ; then
        echo "Running IN-PLACE rollback"
        flashback_source_to_pre_upgrade
else
        echo "Running DATAGUARD rollback"
        # drop_rman_catalog # catalog will untouched until after the migration
        drop_target_database
        drop_target_archivelogs
        remove_target_oratemp_files
        remove_target_from_crs
        update_net_admin_files
        remove_target_dbs_files
        remove_tpm_password_file
        #create_rman_catalog # catalog will untouched until after the migration
        remove_target_oratab_oramon
        uncomment_source_oratab_oramon
        disable_source_data_guard     # Don't want to bounce the source database more than needed
        drop_source_standby_logs
        drop_source_restore_point
        archive_log_current
        enable_remove_archived_logs
fi


<<COMMENT
COMMENT

WRAP_UP
