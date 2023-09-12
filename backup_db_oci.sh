#!/bin/bash

# Description : script to backup to an oracle OCI bucket
# Author : Amaury FRANCOIS <amaury.francois@oracle.com>, Xavier Joanne <xavier.joanne@oracle.com>

export PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin

OCI_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
. $OCI_SCRIPT_DIR/utils.sh
FORMATTED_DATE=$(date +%Y-%m-%d_%H-%M-%S)
CHECK_ONLY=false
OCI_RMAN_PARALLELISM=$OCI_RMAN_DEFAULT_PARALLELISM
OCI_KEEP_DAYS=$OCI_RMAN_DEFAULT_RETENTION

function usage {
cat <<!
Usage: $0 -d <DB_NAME> -l <0|1|A> [-p n] [-k nbDAYS|UNLIMITED] -c
    -d <DB_NAME>*
    -l backup type (Incr level 0 | Incr level 1 | ARchivelogs)*
    -p parallelism (From 2 to 48 max.)
    -k retention period in days ( nbDAYS | UNLIMITED)
    -c check only parameters

*: mandatory parameters

!
exit 0;
}

# Check if there is parameter
if [ -z $1 ]; then
   usage
   exit 1
fi

while getopts 'd:l:p:k:c' c
do
  case ${c} in
    d) OCI_DB_NAME=$OPTARG ;;
    l) OCI_BKP_LEVEL=$OPTARG ;;
    p) OCI_RMAN_PARALLELISM=$OPTARG ;;
    k) OCI_KEEP_DAYS=$OPTARG ;;
    c) CHECK_ONLY=true ;;
    ?) usage ;;
    *) usage ;;
  esac
done


if [[ -z $OCI_DB_NAME || -z $OCI_BKP_LEVEL ]]; then
        log_error "Missing mandatory arguments"
        usage
        exit 1
fi

if [[ $OCI_BKP_LEVEL == '0' || $OCI_BKP_LEVEL == '1' || $OCI_BKP_LEVEL == 'A' ]]; then
        log_success "Level $OCI_BKP_LEVEL is valid"
else
        log_error "Level $OCI_BKP_LEVEL is not valid"
        usage
        exit 1
fi

if [ ! -d ${OCI_BKP_LOG_DIR}/$OCI_DB_NAME ]; then
        mkdir ${OCI_BKP_LOG_DIR}/$OCI_DB_NAME
        if [ $? -ne 0 ]; then
                log_error "Error writing log file directory ${OCI_BKP_LOG_DIR}/$OCI_DB_NAME. Exiting."
                exit 1
        fi
fi


if [[ $OCI_BKP_LEVEL =~ [01] ]]; then
        LF=${OCI_BKP_LOG_DIR}/$OCI_DB_NAME/backup-${FORMATTED_DATE}_db_l${OCI_BKP_LEVEL}.log
else
        LF=${OCI_BKP_LOG_DIR}/$OCI_DB_NAME/backup-${FORMATTED_DATE}_arc.log
fi

log_info "Starting backup of database $OCI_DB_NAME, backup type $OCI_BKP_LEVEL with parallelism $OCI_RMAN_PARALLELISM" | tee -a $LF


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

#Getting Database role
DB_ROLE=$(echo -e "set newpage none\nset head off\nset feedback off\nselect database_role from v\$database ;" | sqlplus -s / as sysdba | grep -v "^$")

#Checking if DB is part of a Data Guard configuration
DG_CONFIG=$(echo -e "set newpage none\nset head off\nset feedback off\nselect * from v\$dataguard_config where DB_UNIQUE_NAME not in (select value from v\$parameter where name = 'db_unique_name');" | sqlplus -s / as sysdba | grep -v "^$")
if [[ $DG_CONFIG != '' ]];
then
        DG_CONFIG=YES
        # ORACLE_UNQNAME_SBY=$(echo -e "set newpage none\nset head off\nset feedback off\nselect db_unique_name from v\$dataguard_config where DEST_ROLE in ('PHYSICAL STANDBY','UNKNOWN') and rownum=1 ;" | sqlplus -s / as sysdba | grep -v "^$")
        ORACLE_UNQNAME_SBY=$(echo -e "set newpage none\nset head off\nset feedback off\nselect db_unique_name from v\$dataguard_config where DEST_ROLE in ('PHYSICAL STANDBY','UNKNOWN') and DB_UNIQUE_NAME like 'RFO%';" | sqlplus -s / as sysdba | grep -v "^$")
	# echo "ora home:"$ORACLE_HOME "sid:"  $ORACLE_SID "UNQ Name:" ${ORACLE_UNQNAME} "UNQ Name Standby:" ${ORACLE_UNQNAME_SBY}
	log_info "Database is part of Data Guard configuration." | tee -a $LF
else
        DG_CONFIG=NO
        # echo "ora home:"$ORACLE_HOME "sid:"  $ORACLE_SID "UNQ Name:" ${ORACLE_UNQNAME}
	log_info "Database is not part of Data Guard configuration." | tee -a $LF
fi

#Getting the scan address
message "SCAN address" | tee -a $LF
get_scan_addr $OCI_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when getting the local SCAN address. Exiting." | tee -a $LF
        exit 1
fi

#Check if DBcredentials are presents for this database
message "DB Credentials in wallet verification" | tee -a $LF
check_cred $OCI_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when checking credentials presence in wallet for this database. Exiting." | tee -a $LF
        exit 1
fi
#Check if RMAN credentials are presents for this database
#message "RMAN Credentials in wallet verification" | tee -a $LF
#check_rman_cred $OCI_DB_NAME
#if [ $? -ne 0 ]; then
#        log_error "Error when checking RMAN catalog user credentials presence in wallet for this database. Exiting." | tee -a $LF
#        exit 1
#fi

#Checking and creating TNS conf
message "TNS and wallet configuration" | tee -a $LF
create_check_tns $OCI_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when checking or creating TNS configuration. Exiting." | tee -a $LF
        exit 1
fi

#Checking database connection
message "Database connection" | tee -a $LF
check_db_connection $OCI_DB_NAME
if [ $? -ne 0 ]; then
        log_error "Error when checking database connection. Exiting." | tee -a $LF
        exit 1
fi

#Checking RMAN connection
#message "RMAN catalog user connection" | tee -a $LF
#check_rman_connection $OCI_DB_NAME
#if [ $? -ne 0 ]; then
#        log_info "Warning: Not using RMAN Catalog but control file" | tee -a $LF
#fi

# If launch with check_only setting, exiting now.
if [ $CHECK_ONLY == 'true' ] ; then
        log_info "Finish running checks. Exiting" | tee -a $LF
        exit 0
fi

#Configuring RMAN
message "RMAN Configuration" | tee -a $LF
config_rman $OCI_DB_NAME $OCI_RMAN_PARALLELISM $OCI_KEEP_DAYS
if [ $? -ne 0 ]; then
        log_error "Error when configuring RMAN. Exiting." | tee -a $LF
        exit 1
fi


if [[ $OCI_BKP_LEVEL =~ [01] ]]; then
message "Backup Wallet to Object storage"
# Copy the wallet in 2 tar files
(cd /var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/ && tar -zcvf /tmp/wallet_$OCI_DB_NAME.tar.gz tde/cwallet.sso tde/ewallet.p12)
CURR_DATE=$(date +%Y-%m-%d_%H%M%S)
cp /tmp/wallet_$OCI_DB_NAME.tar.gz /tmp/wallet_${OCI_DB_NAME}_${CURR_DATE}.tar.gz

#Set oci_* variables necessary to the upload script so that. All information is extracted from credential wallet
oci_tenancy_ocid=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci | cut -f3 -d ' ' | cut -f 1 -d '/')
oci_user_ocid=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci | cut -f3 -d ' ' | cut -f 2 -d '/')
oci_fingerprint=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci | cut -f3 -d ' ' | cut -f 3 -d '/')
oci_region=$(echo $OCI_BKP_OS_URL | cut -d '.' -f2)
OCI_PRIV_KEY=/tmp/temp_priv_key.pem
OCI_PRIV_KEY_INDEX=$($ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep alias_oci |cut -f1 -d':')
echo "-----BEGIN RSA PRIVATE KEY-----" > $OCI_PRIV_KEY
$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -viewEntry oracle.security.client.password${OCI_PRIV_KEY_INDEX} | grep oracle.security.client.password -A 64 | sed -e 's/oracle.*= //'>> $OCI_PRIV_KEY
echo "-----END RSA PRIVATE KEY-----" >> $OCI_PRIV_KEY
oci_private_key_path=$OCI_PRIV_KEY
export oci_private_key_path oci_region oci_fingerprint oci_user_ocid oci_tenancy_ocid

#Upload the 2 files. First one will replace current. Second to have an history
# echo ENV=$ENV
(cd /tmp && $OCI_BKP_ROOT_DIR/bin/uploadoci wallet_$OCI_DB_NAME.tar.gz  ${OCI_BKP_BUCKET_PREFIX}${ENV}_TDE_WALLETS)
if [ $? -ne 0 ]; then
        log_error "Error when uploading wallet backup to bucket ${OCI_BKP_BUCKET_PREFIX}${ENV}_TDE_WALLETS. Exiting." | tee -a $LF
        exit 1
fi

(cd /tmp && $OCI_BKP_ROOT_DIR/bin/uploadoci wallet_${OCI_DB_NAME}_${CURR_DATE}.tar.gz  ${OCI_BKP_BUCKET_PREFIX}${ENV}_TDE_WALLETS)
if [ $? -ne 0 ]; then
        log_error "Error when uploading wallet backup to bucket ${OCI_BKP_BUCKET_PREFIX}${ENV}_TDE_WALLETS. Exiting." | tee -a $LF
        exit 1
fi
#Clean up
rm /tmp/wallet_$OCI_DB_NAME.tar.gz /tmp/wallet_${OCI_DB_NAME}_${CURR_DATE}.tar.gz
rm $OCI_PRIV_KEY
fi

message "RMAN backup" | tee -a $LF
set -o pipefail
CATALOG=''
if [[ $USE_CATALOG == 'YES' ]]; then
        CATALOG="catalog /@RC${OCI_DB_NAME}"
else
        log_info "Backup done with control file only. Continuing" | tee -a $LF
fi

THE_DATE=`date +%d%m%Y_%H%M`
if [[ $OCI_BKP_LEVEL =~ [01] ]]; then
	if [ $OCI_BKP_LEVEL == 0 ]; then
		DESCR=L0
	else
		DESCR=L1
	fi
        (rman target /@$OCI_DB_NAME $CATALOG << EOF
set echo on;
crosscheck backup;
backup device type sbt_tape incremental level $OCI_BKP_LEVEL database include current controlfile section size $OCI_RMAN_SECTION_SIZE tag='${OCI_REG}_${OCI_DB_NAME}_${DESCR}_${THE_DATE}';
delete noprompt obsolete recovery window of ${OCI_KEEP_DAYS} days device type sbt ;
EOF
) | tee -a $LF

        if [ $? -ne 0 ]; then
                log_error "Error when backing up the database . Exiting." | tee -a $LF
                exit 1
        fi
        log_success "Backup of database level ${OCI_BKP_LEVEL} OK." | tee -a $LF
else
        (rman target /@$OCI_DB_NAME $CATALOG << EOF
set echo on;
crosscheck archivelog all;
backup device type sbt_tape archivelog all not backed up 1 times tag='${OCI_REG}_${OCI_DB_NAME}_ARC_${THE_DATE}' ;
EOF
)| tee -a $LF

        if [ $? -ne 0 ]; then
                log_error "Error when backing up the archive logs . Exiting." | tee -a $LF
                exit 1
        fi
        log_success "Backup of archive logs OK." | tee -a $LF
fi
