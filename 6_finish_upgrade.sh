#!/bin/bash


################################
# Comment source oratab oramon #
################################
comment_source_oratab_oramon() {
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

#########################
# Delete tpm known host #
#########################
delete_tpm_known_host() {
echo "$function_header"
echo "Started $FUNCNAME"
sed -i "/${actvsid}.oracle/d" ~/.ssh/known_hosts
echo "Completed $FUNCNAME"
}

#############################
# Disable commvault backups #
#############################
disable_commvault_backups () {
echo "$function_header"
echo "Started $FUNCNAME"
commvault_server="commvault_prd1.bar.tla.uprr.com"
commvault_status=$(/usr/openv/hds/Base64/qoperation execute -cs $commvault_server -af commvault_templates/get_subclient_prop_template.xml -appName 'Oracle' -clientName $srchost -instanceName $srcsid -subclientName ${srcsid}_rman_arc|tr ' ' '\n'|grep -e enableBackup=)
if [[ ! $commvault_status = "enableBackup"* ]]; then
        commvault_server="commvault_prd2.bar.tla.uprr.com"
        commvault_status=$(/usr/openv/hds/Base64/qoperation execute -cs $commvault_server -af commvault_templates/get_subclient_prop_template.xml -appName 'Oracle' -clientName $srchost -instanceName $srcsid -subclientName ${srcsid}_rman_arc|tr ' ' '\n'|grep -e enableBackup=)
fi
echo "commvault_server is $commvault_server"
echo "Disabling archive log backup"
/usr/openv/hds/Base64/qoperation execute -cs $commvault_server -af commvault_templates/update_subclient_template.xml -appName Oracle -clientName $srchost -instanceName $srcsid -subclientName ${srcsid}_rman_arc -enableBackup false
echo "Disabling full database backup"
/usr/openv/hds/Base64/qoperation execute -cs $commvault_server -af commvault_templates/update_subclient_template.xml -appName Oracle -clientName $srchost -instanceName $srcsid -subclientName ${srcsid}_rman -enableBackup false
echo "Disabling cold backup"
/usr/openv/hds/Base64/qoperation execute -cs $commvault_server -af commvault_templates/update_subclient_template.xml -appName Oracle -clientName $srchost -instanceName $srcsid -subclientName ${srcsid}_cold -enableBackup false
echo "Completed $FUNCNAME"
}

########################
# Disable dma_purg_wrh #
########################
disable_dma_purg_wrh () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "
begin
  sys.dbms_scheduler.disable (name  => 'sys.dma_purg_wrh');
end;
/
"
}

###################
# Enable LOCK_SGA #
###################
enable_lock_sga () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter system set lock_sga=TRUE scope=spfile;"
}

##########################
# Enable System Triggers #
##########################
enable_system_triggers() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT '
alter system set "_system_trig_enabled"=true;
'
echo "Completed $FUNCNAME"
}

############################
# Shutdown source database #
############################
shutdown_source_database() {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_SRC "shutdown immediate;"
echo "Completed $FUNCNAME"
}

###################################
# set pga_aggregate_limit to zero #
###################################
set_pga_aggregate_limit_to_zero () {
echo "$function_header"
echo "Started $FUNCNAME"
EXEC_SQL_ON_TGT "alter system set pga_aggregate_limit=0 scope=both;"
echo "Completed $FUNCNAME"
}

##################################
# Update oracle home oncommvault #
##################################
update_oracle_home_on_commvault () {
echo "$function_header"
echo "Started $FUNCNAME"
/usr/openv/hds/Base64/qlogin -u oracle -clp oscar
/upapps/dte/oracle-administrative-scripts/v1.0/commvault_oracle_home_update.sh ${tgtsid}
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


enable_system_triggers
enable_lock_sga
disable_dma_purg_wrh
set_pga_aggregate_limit_to_zero

[ "$srchost" != "$tgthost" ] && shutdown_source_database
[ "$srchost" != "$tgthost" ] && comment_source_oratab_oramon
if [ "$srchost" != "$tgthost" ]; then
        delete_tpm_known_host
        disable_commvault_backups                                               # backup will be created in SCP job flow
else
        update_oracle_home_on_commvault
fi
recreate_rman_catalog
update_oem


<<COMMENT
COMMENT

WRAP_UP
