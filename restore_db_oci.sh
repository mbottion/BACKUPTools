#!/bin/bash

# Description : script to restore from an oracle OCI bucket
# Author : Amaury FRANCOIS <amaury.francois@oracle.com>
#          Xavier JOANNE <xavier.joanne@oracle.com>

OCI_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
. $OCI_SCRIPT_DIR/utils.sh
FORMATTED_DATE=$(date +%Y-%m-%d_%H-%M-%S)
PROMPT=true
while getopts 'd:t:p:i:n' c
do
  case $c in
    d) OCI_DB_NAME=$OPTARG ;;
    t) OCI_BKP_DATE=$OPTARG ;;
    n) PROMPT=false ;;
    p) OCI_RMAN_PARALLELISM=$OPTARG ;;
    i) OCI_DBID=$OPTARG ;;
  esac
done

if [[ -z $OCI_DB_NAME || -z $OCI_DBID || -z $OCI_BKP_DATE ]]; then
	log_error "Missing arguments"
	message "Usage : $0 -d <DB_NAME> -i <DBID> -t <2019-12-25_13:31:40> [-p n] [-n(oprompt)]"

	exit 1
fi

if [[ ! $OCI_BKP_DATE =~ ^20[0-9][0-9]-[01][0-9]-[0-3][0-9]_[0-2][0-9]:[0-5][0-9]:[0-5][0-9]$ ]]; then 
	log_error "Date format does not match : 20YY-MM-DD_HH24:MI:SS"
	exit 1
fi

if [ ! -d ${OCI_BKP_LOG_DIR}/$OCI_DB_NAME ]; then
	mkdir ${OCI_BKP_LOG_DIR}/$OCI_DB_NAME 
	if [ $? -ne 0 ]; then
		log_error "Error writing log file directory ${OCI_BKP_LOG_DIR}/$OCI_DB_NAME. Exiting."	
		exit 1
	fi
fi


LF=${OCI_BKP_LOG_DIR}/$OCI_DB_NAME/restore_db_-${FORMATTED_DATE}.log

if [ ! -z $OCI_BKP_DATE ]; then 
	DATE_MES=" at time $OCI_BKP_DATE"
else
	DATE_MES=" at latest possible time"
fi

log_info "Starting restore of database $OCI_DB_NAME $DATE_MES" | tee -a $LF

#Loading DB env
message "DB environment loading" | tee -a $LF
load_db_env $OCI_DB_NAME 
if [ $? -ne 0 ]; then 
	log_error "Error when loading the environment. Exiting." | tee -a $LF
	exit 1
fi

#Checking if configuration exist, if not creating it
message "OCI Backup Configuration" | tee -a $LF
create_check_config $OCI_DB_NAME 

if [ $? -ne 0 ]; then 
	log_error "Error when checking or creating configuration file . Exiting." | tee -a $LF
	exit 1
fi

#Getting the scan address
message "SCAN address" | tee -a $LF
get_scan_addr $OCI_DB_NAME 
if [ $? -ne 0 ]; then 
	log_error "Error when getting the local SCAN address. Exiting." | tee -a $LF
	exit 1
fi

#Check if credentials are presents for this database
message "Credentials in wallet verification" | tee -a $LF
check_cred $OCI_DB_NAME 
if [ $? -ne 0 ]; then 
	log_error "Error when checking credentials presence in wallet for this database. Exiting." | tee -a $LF
	exit 1
fi
#Checking and creating TNS conf
message "TNS and wallet configuration" | tee -a $LF
create_check_tns $OCI_DB_NAME 
if [ $? -ne 0 ]; then 
	log_error "Error when checking or creating TNS configuration. Exiting." | tee -a $LF
	exit 1
fi

[[ $PROMPT == "true" ]] && ask_confirm "This command will stop and drop $OCI_DB_NAME"

message "Stopping and Dropping the database" | tee -a $LF
log_info "Getting database status on all nodes" | tee -a $LF
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Stopping database on all nodes" | tee -a $LF
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME

log_info "Getting database status on all nodes" | tee -a $LF
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Disabling cluster mode" | tee -a $LF
OCI_BKP_TNS_ADMIN=$TNS_ADMIN
unset TNS_ADMIN
sqlplus -s / as sysdba << EOF
prompt Starting nomount ...
startup nomount;
prompt
prompt Setting cluster_database to false ... 
alter system set cluster_database=false scope=spfile;
prompt Shutting down ...
shutdown immediate;
prompt
EOF

log_info "Starting in mount exclusive restrict" | tee -a $LF
sqlplus -s / as sysdba << EOF
prompt Starting mount exclusive restrict ...
startup mount exclusive restrict;
EOF

log_info "Checking database state" | tee -a $LF
DB_STATE=$(sqlplus -s / as sysdba << EOF
set feed off 
select status from gv\$instance;
EOF
)

if [[ $DB_STATE =~ "MOUNTED" ]]; then
	log_success "Database ready to be dropped" | tee -a $LF
else
	log_error "Unable to restart the database in exclusive restrict mode. Continuing." | tee -a $LF
	# exit 1
fi

log_info "Dropping the database using RMAN" | tee -a $LF
rman target / << EOF
drop database noprompt;
EOF

export TNS_ADMIN=$OCI_BKP_TNS_ADMIN

message "Restoring TDE Wallet from Object storage" | tee -a $LF

# Set oci_* variables necessary to the upload script so that. All information is extracted from credential wallet
oci_tenancy_ocid=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci | cut -f3 -d ' ' | cut -f 1 -d '/')
oci_user_ocid=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci | cut -f3 -d ' ' | cut -f 2 -d '/')
oci_fingerprint=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci | cut -f3 -d ' ' | cut -f 3 -d '/')
oci_region=$(echo $OCI_BKP_OS_URL | cut -d '.' -f2)
OCI_PRIV_KEY=/tmp/temp_${OCI_DB_NAME}_priv_key.pem
OCI_PRIV_KEY_INDEX=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci |cut -f1 -d':')
echo "-----BEGIN RSA PRIVATE KEY-----" >> $OCI_PRIV_KEY
$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -viewEntry oracle.security.client.password${OCI_PRIV_KEY_INDEX} | grep oracle.security.client.password -A 64 | sed -e 's/oracle.*= //'>> $OCI_PRIV_KEY
echo "-----END RSA PRIVATE KEY-----" >> $OCI_PRIV_KEY
oci_private_key_path=$OCI_PRIV_KEY
export oci_private_key_path oci_region oci_fingerprint oci_user_ocid oci_tenancy_ocid

#Download
(cd /tmp && $OCI_BKP_ROOT_DIR/bin/downloadoci wallet_${OCI_DB_NAME}.tar.gz  ${OCI_BKP_BUCKET_PREFIX}${ENV}_TDE_WALLETS wallet_${OCI_DB_NAME}.tar.gz)
if [ $? -ne 0 ]; then
        log_error "Error when downloading wallet backup from bucket ${OCI_BKP_BUCKET_PREFIX}${ENV}_TDE_WALLETS. Exiting." | tee -a $LF
        exit 1
fi

log_info "Moving current wallet directory" | tee -a $LF

CURR_DATE=$(date +%Y-%m-%d_%H%M%S)
if [ -d /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/tde ]; then
        if [ ! -d /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/tde_wallet_restore_archive ]; then
        	mkdir /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/tde_wallet_restore_archive
        fi
        (cd  /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root && mv tde tde_wallet_restore_archive/tde_wallet.${CURR_DATE})
	mkdir -p /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/tde

fi

log_info "Untarrring backup wallet to target wallet" | tee -a $LF

tar -zxvf /tmp/wallet_${OCI_DB_NAME}.tar.gz -C /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root
if [ $? -ne 0 ]; then
        log_error "Error when Untarring wallet_${OCI_DB_NAME}.tar.gz to /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root. Exiting." | tee -a $LF
        exit 1
fi

# ls -la /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/tde

log_success "Wallet of ${OCI_DB_NAME} was copied to /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root" | tee -a $LF

rm /tmp/wallet_${OCI_DB_NAME}.tar.gz

message "Spfile Restore" | tee -a $LF

log_info "Restoring the spfile to a temporary pfile" | tee -a $LF
TEMP_PFILE=$(mktemp)

# rman target / catalog /@RC${OCI_DB_NAME} << EOF
rman target /  << EOF
set echo on;
startup nomount;
set DBID=$OCI_DBID
RUN {
SET CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE 'SBT_TAPE' TO '%F';
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
RESTORE SPFILE TO PFILE '$TEMP_PFILE' FROM AUTOBACKUP ;
}
shutdown immediate;
EOF

# Clean previous spfile if still exists
log_info "Erasing previous spfile in diskgroup" | tee -a $LF
asmcmd --privilege sysdba  ls $DG_DATA/$OCI_BKP_DB_UNIQUE_NAME/PARAMETERFILE/spfile*
asmcmd --privilege sysdba  rm $DG_DATA/$OCI_BKP_DB_UNIQUE_NAME/PARAMETERFILE/*

SPFILE_LOC=$(srvctl config database -d $OCI_BKP_DB_UNIQUE_NAME | grep "^Spfile" | awk '{print $2}')

log_info "Previous spfile: $SPFILE_LOC" | tee -a $LF
sqlplus -s / as sysdba << EOF
prompt Startup on temp pfile ...
startup nomount pfile='$TEMP_PFILE';
prompt
prompt Creating the spfile ...
create spfile='$DG_DATA' from pfile='$TEMP_PFILE';
prompt Shutting down ...
shutdown immediate;
EOF

NEW_SPFILE_LOC="$DG_DATA/$OCI_BKP_DB_UNIQUE_NAME/PARAMETERFILE/"$(asmcmd --privilege sysdba ls ${DG_DATA}/${OCI_BKP_DB_UNIQUE_NAME}/PARAMETERFILE | grep spfile)
log_info "Spfile restored as $NEW_SPFILE_LOC" | tee -a $LF
log_info "Modifying cluster resource with new spfile name" | tee -a $LF

srvctl modify database -d $OCI_BKP_DB_UNIQUE_NAME -spfile $NEW_SPFILE_LOC

log_info "Starting the database with restored spfile" | tee -a $LF
srvctl start database -d $OCI_BKP_DB_UNIQUE_NAME -o nomount
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

log_info "Checking database state" | tee -a $LF
DB_STATE=$(sqlplus -s / as sysdba << EOF
set feed off 
select inst_id, status from gv\$instance;
EOF
)

if [[ $DB_STATE =~ "STARTED" ]]; then
	log_success "Database is in NOMOUNT state"
else
	log_error "Unable to start the database in NOMOUNT mode. Exiting"
	exit 1
fi

log_info "Checking spfile is in use" | tee -a $LF
SPFILE_RUNTIME_LOC=$(sqlplus -s / as sysdba << EOF
set feed off head off
select value from v\$parameter where name='spfile';
EOF
)

SPFILE_RUNTIME_LOC=$(echo $SPFILE_RUNTIME_LOC | tr -d '\n')
if [[ ${SPFILE_RUNTIME_LOC,,} == ${NEW_SPFILE_LOC,,} ]]; then
	log_success "Database is in NOMOUNT state with an ASM spfile" | tee -a $LF
else
	log_error "Database is not using the ASM spfile. Exiting" | tee -a $LF
	exit 1
fi

rm -f $TEMP_PFILE

message "Control file restore" | tee -a $LF

export TNS_ADMIN=$OCI_BKP_TNS_ADMIN
log_info "Restoring the controlfile" | tee -a $LF

# RMAN catalog mandatory to specify set until time clause.

rman target / << EOF
set echo on;
set DBID=$OCI_DBID
run
{
set until time "to_date('$OCI_BKP_DATE', 'yyyy-mm-dd_hh24:mi:ss')";
set controlfile autobackup format for device type 'sbt_tape' to '%F';
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
restore controlfile from autobackup;
}
EOF

# If restore is before the last open resetlogs, an older incarnation must be provided
# Uncomment this bloc and provide the incarnation nimber to be used

# log_info "Reseting the incarnation" | tee -a $LF
# srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -o abort
# rman target / <<EOF
# startup mount;
# RESET DATABASE TO INCARNATION XXXXXXX;
# EOF

log_info "Restarting the database in MOUNT mode" | tee -a $LF
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -o abort
srvctl start database -d $OCI_BKP_DB_UNIQUE_NAME -o mount
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v


log_info "Checking database state" | tee -a $LF
DB_STATE=$(sqlplus -s / as sysdba << EOF
set feed off 
select status from gv\$instance;
EOF
)

if [[ $DB_STATE =~ "MOUNTED" ]]; then
	log_success "Database started in MOUNT mode " | tee -a $LF
else
	log_error "Unable to restart the database in MOUNT mode. Exiting" | tee -a $LF
	exit 1
fi

message "Database restore and recover" | tee -a $LF
rman target /@$OCI_DB_NAME << EOF
run {
set until time "to_date('$OCI_BKP_DATE', 'yyyy-mm-dd_hh24:mi:ss')";
ALLOCATE CHANNEL ch1 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch2 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch3 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch4 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch5 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch6 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch7 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch8 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch9 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch10 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch11 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch12 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch13 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch14 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch15 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
ALLOCATE CHANNEL ch16 DEVICE TYPE sbt PARMS 'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${OCI_DB_NAME}.ora)';
restore database;
recover database;
}
EOF

# log_info "Disabling BCT if needed"
# sqlplus -s / as sysdba << EOF
# ALTER DATABASE DISABLE BLOCK CHANGE TRACKING;
# EOF

log_info "Stopping database" | tee -a $LF

srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME -stopoption immediate

log_info "Opening the database with resetlogs" | tee -a $LF
sqlplus -s / as sysdba << EOF
startup mount;
ALTER DATABASE OPEN RESETLOGS;
EOF

log_info "Restarting the database in OPEN mode" | tee -a $LF
srvctl stop database -d $OCI_BKP_DB_UNIQUE_NAME
srvctl start database -d $OCI_BKP_DB_UNIQUE_NAME
srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v

# log_info "Activating BCT" | tee -a $LF
# sqlplus -s / as sysdba << EOF
# prompt Enable BCT on ${DG_DATA} ...
# ALTER DATABASE ENABLE BLOCK CHANGE TRACKING USING FILE '${DG_DATA}';
# EOF

DB_SRVCTL_LINES=$(srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME | wc -l)
DB_SRVCTL_OPEN=$(srvctl status database -d $OCI_BKP_DB_UNIQUE_NAME -v | grep -c Open)

if [ $DB_SRVCTL_LINES -eq $DB_SRVCTL_OPEN ]; then
	log_success "Restore database OK" | tee -a $LF
else
	log_error "Problem when restoring the database. Exiting." | tee -a $LF
	exit 1
fi
