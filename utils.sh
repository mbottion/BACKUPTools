#!/bin/bash

UTILS_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OCI_BKP_ROOT_DIR=$(dirname $UTILS_SCRIPT_DIR)

#Backup default values
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
export OCI_RMAN_DEFAULT_PARALLELISM=16
export USE_CATALOG=NO
export HOSTNAME=`hostname -s`
export DG_DATA=+DATAC1
export DG_RECO=+RECOC1

OCI_REG_IDENTIFIER=$(curl -s http://169.254.169.254/opc/v1/instance/ |grep regionIdentifier | awk -F"\""  '{print $4}' )
OCI_REG=$(curl -s http://169.254.169.254/opc/v1/instance/ |grep regionKey | awk -F"\""  '{print $4}' )
OCI_RMAN_SECTION_SIZE="16G"
OCI_RMAN_DEFAULT_RETENTION=60
OCI_RMAN_BACKUP_ALGORITHM=LOW
# OCI_RMAN_IP_SERVER1=          # Primary DB
# OCI_RMAN_IP_SERVER2=         # Standby DB
# OCI_RMAN_HOSTNAME_SERVER1=
# OCI_RMAN_HOSTNAME_SERVER2=
# OCI_RMAN_CATALOG_PORT=1521
# OCI_RMAN_SERVICE=
OCI_ARCH_RETENTION=30
OCI_BKP_OS_URL=https://objectstorage.${OCI_REG_IDENTIFIER}.oraclecloud.com/n/axagx9w68uqo
OCI_BKP_BUCKET_PREFIX=${OCI_REG}_EBS_RMAN_BACKUP_

if [[ `hostname -f | cut -d. -f2 | cut -c1-3` == prd ]]; then
	# PRD compartment in Paris
        OCI_BKP_COMPARTMENT_OCID=ocid1.compartment.oc1..aaaaaaaaceoz5ukth7tdmb66mbrmn3l2hs5mpw7gha7qezc2kmanmwifkonq
	export ENV=PRD
elif [[ `hostname -f | cut -d. -f2 | cut -c10-12` == drp ]]; then
        # DRP compartment in Frankfurt
        OCI_BKP_COMPARTMENT_OCID=ocid1.compartment.oc1..aaaaaaaa2mtjgbqjervsg2iv4locw7qefucnvkyst2goyc6cx45nlor4zydq
        export ENV=PRD
else
        OCI_BKP_COMPARTMENT_OCID=ocid1.compartment.oc1..aaaaaaaa4mmprxwklhghddbijgsf3b4dy5icvrcxj5acvidhmqbl7jvqkmnq
        export ENV=NPR
fi

OCI_BKP_LIB=$OCI_BKP_ROOT_DIR/lib/libopc.so
OCI_BKP_CONFIG_DIR=$OCI_BKP_ROOT_DIR/config
OCI_BKP_CREDWALLET_DIR=/acfs01/backup_oci/cred_wallet
OCI_BKP_TNS_DIR=$OCI_BKP_ROOT_DIR/tns
OCI_BKP_LOG_DIR=$OCI_BKP_ROOT_DIR/logs

#Functions
create_check_config(){

log_info "Checking if database config file exists"
if [ ! -f $OCI_BKP_CONFIG_DIR/opc${1}.ora ]; then
log_info "Configuration file for database $1 does not exist, creating it"
cat << EOF > $OCI_BKP_CONFIG_DIR/opc${1}.ora
OPC_HOST=$OCI_BKP_OS_URL
OPC_WALLET='LOCATION=file:/acfs01/backup_oci/cred_wallet/${OCI_DB_NAME}  CREDENTIAL_ALIAS=alias_oci'
OPC_CONTAINER=${OCI_BKP_BUCKET_PREFIX}${1}
OPC_COMPARTMENT_ID=$OCI_BKP_COMPARTMENT_OCID
OPC_AUTH_SCHEME=BMC
EOF
fi
log_success "Database config file exists"

log_info "Checking if credential wallet exists"
if [ -f $OCI_BKP_CREDWALLET_DIR/cwallet.sso ]; then
	log_success "Credential wallet exists"
else
	log_error "Credential wallet does not exist in $OCI_BKP_CREDWALLET_DIR"
	return 1
fi
}

load_db_env(){
log_info "Checking database presence in /etc/oratab"
export OCI_BKP_DB_UNIQUE_NAME=$(grep "^${1}" /etc/oratab | grep 1GN | cut -d':' -f1)
export OCI_BKP_ORACLE_HOME=$(grep "^${1}" /etc/oratab | head -1 | cut -d':' -f2)

if [[ -z $OCI_BKP_DB_UNIQUE_NAME || -z $OCI_BKP_ORACLE_HOME ]]; then
	log_error "Error getting database information in /etc/oratab"
	return 1
else
	export ORACLE_HOME=$OCI_BKP_ORACLE_HOME
	export PATH=$ORACLE_HOME/bin:$PATH
	export ORACLE_SID=${1}${HOSTNAME: -1}
fi

log_success "Database $1 is present in /etc/oratab"

}

get_scan_addr(){
log_info "Checking local SCAN address"
#export ORACLE_HOME=$OCI_BKP_ORACLE_HOME
export OCI_SCAN_ADDR=$($ORACLE_HOME/bin/srvctl config scan | grep -v "SCAN VIP" | grep -oP "(?<=name: ).*(?=,)")

if [ $? -ne 0 ]; then
	log_error "Error getting local SCAN address"
	return 1
fi

log_success "Local SCAN address is : $OCI_SCAN_ADDR"

}

create_check_tns(){
log_info "Checking or creating tnsnames.ora"
if [ ! -d $OCI_BKP_TNS_DIR/$1 ]; then
	mkdir $OCI_BKP_TNS_DIR/$1
fi

# Get DB Listener port
LISTENER_PORT=`srvctl config listener | grep 'End points' | cut -d':' -f3 | cut -d'/' -f1`

if [ -z $LISTENER_PORT ]; then
        log_error "Failed to compute local listener port for $1. Exiting" | tee -a $LF
        exit 1
fi

if [ ! -f $OCI_BKP_TNS_DIR/$1/tnsnames.ora ]; then
cat > $OCI_BKP_TNS_DIR/$1/tnsnames.ora << EOF
$1 =
  (DESCRIPTION=
     (ADDRESS_LIST=
        (LOAD_BALANCE=YES)
        (FAILOVER=YES)
        (ADDRESS=(PROTOCOL=tcp)(HOST=$OCI_SCAN_ADDR)(PORT=${LISTENER_PORT}))
     )
     (CONNECT_DATA= 
        (UR=A)
        (SERVER = DEDICATED)
        (SERVICE_NAME=${OCI_BKP_DB_UNIQUE_NAME}.prdintexc.parfopvcnprdint.oraclevcn.com)
     )
   )
EOF
fi

log_info "Checking or creating sqlnet.ora"
if [ ! -f $OCI_BKP_TNS_DIR/$1/sqlnet.ora ]; then
cat > $OCI_BKP_TNS_DIR/$1/sqlnet.ora << EOF
WALLET_LOCATION =(SOURCE=(METHOD = FILE)(METHOD_DATA=(DIRECTORY = $OCI_BKP_CREDWALLET_DIR)))
SQLNET.WALLET_OVERRIDE = TRUE

ENCRYPTION_WALLET_LOCATION =
 (SOURCE=
  (METHOD=FILE)
   (METHOD_DATA=
    (DIRECTORY=/var/opt/oracle/dbaas_acfs/${OCI_DB_NAME}/wallet_root/tde)))
EOF
fi
export TNS_ADMIN=$OCI_BKP_TNS_DIR/$1
}

check_db_connection()
{
rman target /@$1 >/dev/null 2>&1<< EOF
EOF
if [ $? -ne 0 ]; then
        echo $TNS_ADMIN
        echo rman target /@$1
	log_error "Not able to connect to the database using local TNS configuration."
	return 1
else
	log_success "TNS configuration and connection to the database is OK"
fi
}

check_sys_db_password()
{
STATUS=$(echo -e "set newpage none\nset head off\nset feedback off\nselect 'OK' from dual ;" | sqlplus -s sys/$2@$1 as sysdba | grep -v "^$")
if [ "$STATUS" != "OK"  ]; then
        log_error "Can't connect to the database as SYS with provided password. "
        return 1
else
        log_success "Successfully connect SYS with provided paswword. Continuing"
fi
}

check_rman_connection()
{
rman target /@$1 catalog /@RC$1 >/dev/null 2>&1<< EOF
EOF
if [ $? -ne 0 ]; then
	log_error "Not able to connect to the RMAN catalog using local TNS configuration"
	log_info  "Warning: Using control file for backup instead of RMAN catalog"
	USE_CATALOG=NO
else
	log_success "TNS configuration and connection to the RMAN catalog are OK"
	USE_CATALOG=YES
fi
}

check_rman_password()
{
RCUSER=RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'`
rcuser=rc`echo $1 | cut -c1-4 | tr '[:upper:]' '[:lower:]'`
rman catalog $RCUSER/"${2}"@RC$1 >/dev/null 2>&1<< EOF
EOF
if [ $? -ne 0 ]; then
        log_error "Can't connect to the RMAN catalog using provided password. Exiting"
else
        log_success "Connection to the RMAN Catalog with provided passwd is OK"
fi
}

check_cred() {
$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep $1 |grep -v RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'`  > /dev/null 2>&1
if [ $? -ne 0 ]; then
	log_error "No Entry for $1 in wallet $OCI_BKP_CREDWALLET_DIR. Please add the entry using mkstore command"
	return 1
else
	log_success "Entry for $1 found in wallet $OCI_BKP_CREDWALLET_DIR"
fi
}

check_rman_cred() {
$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep -i RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'` > /dev/null 2>&1
if [ $? -ne 0 ]; then
	log_error "No Entry for RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'` (RMAN catalog user) in wallet $OCI_BKP_CREDWALLET_DIR. Please add the entry using mkstore command"
	return 1
else
	log_success "Entry for RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'` (RMAN catalog user) found in wallet $OCI_BKP_CREDWALLET_DIR"
fi
}

add_cred() {
EXIST=`$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep $1 | grep -v RC$1 | wc -l `
if [ $EXIST -eq 0 ]; then
	$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -createCredential $OCI_DB_NAME sys "${2}" >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		log_error "Failed to add DB Credentials into the store. Exiting"
		exit 1
	else
		log_success "DB Credentials added into the store. Continuing"
	fi
else
	log_info "DB Credentials already existing in the store. Continuing"
fi
}

add_rman_cred() {
RCUSER=RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'`
rcuser=rc`echo $1 | cut -c1-4 | tr '[:upper:]' '[:lower:]'`
EXIST=`$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -listCredential | grep "^[0-9]" | grep RC`echo $1 | cut -c1-4 | tr '[:lower:]' '[:upper:]'` | wc -l `
if [ $EXIST -eq 0 ]; then
	$ORACLE_HOME/bin/mkstore -wrl $OCI_BKP_CREDWALLET_DIR -createCredential $RCUSER $rcuser "${2}" >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		log_error "Failed to add RMAN Credentials into the store. Exiting"
		exit 1
	else
		log_success "RMAN Credentials added into the store. Continuing"
	fi
else
	log_info "RMAN Credentials already existing in the store. Continuing"
fi
}

read_password() {
PASSWORD=''
PASSWORD2=''
while [ $PASSWORD != $PASSWORD2 ]
do
        PASSWORD=''
        PASSWORD2=''
        prompt="Password: "
        while IFS= read -p "$prompt" -r -s -n 1 char
        do
                if [[ $char == $'\0'  ]]
                then
                        break
                fi
                prompt='*'
                PASSWORD+="$char"
        done
	echo
        prompt="Password again: "
	while IFS= read -p "$prompt" -r -s -n 1 char
        do
		if [[ $char == $'\0'  ]]
		then
			break
                fi
		prompt='*'
		PASSWORD2+="$char"
	done
done
echo $PASSWORD
}

register_db()
{
rman target /@$1 catalog /@RC$1 >/dev/null 2>&1<< EOF
register database;
list incarnation;
EOF
if [ $? -ne 0 ]; then
	log_error "Failed to register DB into the RMAN Catalog"
	return 1
else
	log_success "Succesfully registered DB into the RMAN Catalog"
fi
}

create_catalog ()
{
echo export CIBLEDB=$OCI_DB_NAME                  > $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
echo export CIBLE_RCUSER_PASSWORD=`echo $RMAN_PASSWORD` >> $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
scp $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh oracle@$OCI_RMAN_SERVER:/home/oracle/scripts/rman-catalog >/dev/null 2>&1
if [ $? -ne 0 ];
then
	log_error "Failed to copy $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh to oracle@$OCI_RMAN_SERVER:/home/oracle/scripts/rman-catalog"
	rm -f $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
	exit 1
else
	log_success "Parameter file params_$OCI_DB_NAME.sh copied successfully on serveur $OCI_RMAN_HOSTNAME_SERVER ($OCI_RMAN_SERVER)"
	rm -f $OCI_BKP_ROOT_DIR/config/params_$OCI_DB_NAME.sh
fi
ssh oracle@$OCI_RMAN_SERVER  /home/oracle/scripts/rman-catalog/create_rman_catalog.sh params_${OCI_DB_NAME}.sh
if [ $? -ne 0 ];
then
	log_error "Failed to execute remotly on server $OCI_RMAN_SERVER script /home/oracle/scripts/rman-catalog/create_rman_catalog.sh with oracle user. Exiting"
	log_error "Check SSH equivalency between local user and oracle user on oracle@$OCI_RMAN_HOSTNAME_SERVER ($OCI_RMAN_SERVER)"
	exit 1
else
	log_success "Remote RMAN Catalog creation script execution success on oracle@$OCI_RMAN_HOSTNAME_SERVER ($OCI_RMAN_SERVER)"
fi
}

config_rman() {
if  [[ ${DB_ROLE} = "PRIMARY" ]] && [[ ${DG_CONFIG} = "NO" ]]
then
	# We are backuping the Primary DB
	log_info "Database does not belongs to a Data Guard configuration."
       	log_info "Database has a PRIMARY role."
	rman target /@$1 $CATALOG 2>&1<< EOF
	CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
	CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $OCI_KEEP_DAYS DAYS;
	CONFIGURE BACKUP OPTIMIZATION ON;
	CONFIGURE DEFAULT DEVICE TYPE TO 'SBT_TAPE';
	CONFIGURE CONTROLFILE AUTOBACKUP ON;
	CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE SBT_TAPE TO '%F'; # default
	CONFIGURE DEVICE TYPE 'SBT_TAPE' PARALLELISM $OCI_RMAN_PARALLELISM BACKUP TYPE TO COMPRESSED BACKUPSET;
	CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' PARMS  'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${1}.ora)';
	CONFIGURE ENCRYPTION FOR DATABASE ON;
	CONFIGURE ENCRYPTION ALGORITHM 'AES256'; # default
	CONFIGURE COMPRESSION ALGORITHM '$OCI_RMAN_BACKUP_ALGORITHM' AS OF RELEASE 'DEFAULT' OPTIMIZE FOR LOAD TRUE;
EOF
elif  [[ ${DB_ROLE} = "PRIMARY" ]] && [[ ${DG_CONFIG} = "YES" ]]
then
       	# We are backuping the Pimary DB in a Data Guard configuration
       	log_info "Database belongs to a Data Guard configuration."
       	log_info "Database has a PRIMARY role."
	rman target /@$1 $CATALOG 2>&1<< EOF
	CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
	CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $OCI_KEEP_DAYS DAYS;
	CONFIGURE BACKUP OPTIMIZATION ON;
	CONFIGURE DEFAULT DEVICE TYPE TO 'SBT_TAPE';
	CONFIGURE CONTROLFILE AUTOBACKUP ON;
	CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE SBT_TAPE TO '%F'; # default
	CONFIGURE DEVICE TYPE 'SBT_TAPE' PARALLELISM $OCI_RMAN_PARALLELISM BACKUP TYPE TO COMPRESSED BACKUPSET;
	CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' PARMS  'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${1}.ora)';
	CONFIGURE ENCRYPTION FOR DATABASE ON;
	CONFIGURE ENCRYPTION ALGORITHM 'AES256'; # default
        CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO 'SBT_TAPE';
	CONFIGURE COMPRESSION ALGORITHM '$OCI_RMAN_BACKUP_ALGORITHM' AS OF RELEASE 'DEFAULT' OPTIMIZE FOR LOAD TRUE;
EOF
else
	# We are backuping the Standby DB
	log_info "Database belongs to a Data Guard configuration."
	log_info "Database has a STANDBY role."
	rman target /@$1 $CATALOG 2>&1<< EOF
	CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
	CONFIGURE BACKUP OPTIMIZATION ON;
	CONFIGURE DEFAULT DEVICE TYPE TO 'SBT_TAPE';
	CONFIGURE CONTROLFILE AUTOBACKUP ON;
	CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE SBT_TAPE TO '%F'; # default
	CONFIGURE DEVICE TYPE 'SBT_TAPE' PARALLELISM $OCI_RMAN_PARALLELISM BACKUP TYPE TO COMPRESSED BACKUPSET;
	CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' PARMS  'SBT_LIBRARY=$OCI_BKP_LIB, ENV=(OPC_PFILE=$OCI_BKP_CONFIG_DIR/opc${1}.ora)';
	CONFIGURE ENCRYPTION FOR DATABASE ON;
	CONFIGURE ENCRYPTION ALGORITHM 'AES256'; # default
	CONFIGURE COMPRESSION ALGORITHM '$OCI_RMAN_BACKUP_ALGORITHM' AS OF RELEASE 'DEFAULT' OPTIMIZE FOR LOAD TRUE;
EOF
fi

}

# Display helpers
GREEN=$(tput setaf 6)
BLUE=$(tput setaf 4)
RED=$(tput setaf 1)
NC=$(tput sgr0)

message()
{
echo
echo "-----------------------------------------------------------------"
echo $1
echo "-----------------------------------------------------------------"
}

message_end()
{
echo "-----------------------------------------------------------------"
echo
}

log_info()
{
FDATE=$(date "+%Y-%m-%d %H:%M:%S")
echo
echo -e "$BLUE[INFO]$NC[${FDATE}] $1"
echo
}

log_error()
{
FDATE=$(date "+%Y-%m-%d %H:%M:%S")
echo
echo -e "$RED[ERROR]$NC[${FDATE}] $1"
echo
}

log_success()
{
echo
FDATE=$(date "+%Y-%m-%d %H:%M:%S")
echo -e "$GREEN[SUCCESS]$NC[${FDATE}] $1"
echo
}

ask_confirm(){
echo "$1"
read -p "Are you sure you want to continue ? (y/N) "
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
	exit 1
fi
}
