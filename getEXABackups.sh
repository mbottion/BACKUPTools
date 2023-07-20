VERSION=1.0
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#     Trace
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
startRun()
{
  START_INTERM_EPOCH=$(date +%s)
  START_INTERM_FMT=$(date +"%d/%m/%Y %H:%M:%S")
  echo   "========================================================================================"
  echo   " Execution start"
  echo   "========================================================================================"
  echo   "  - $1"
  echo   "  - Started at     : $START_INTERM_FMT"
  echo   "========================================================================================"
  echo
}
endRun()
{
  END_INTERM_EPOCH=$(date +%s)
  END_INTERM_FMT=$(date +"%d/%m/%Y %H:%M:%S")
  all_secs2=$(expr $END_INTERM_EPOCH - $START_INTERM_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo
  echo   "========================================================================================"
  echo   "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo   "  - Ended at      : $END_INTERM_FMT"
  echo   "  - Duration      : ${mins2}:${secs2}"
  echo   "========================================================================================"
  echo   "Script LOG in : $LOG_FILE"
  echo   "========================================================================================"
}
startStep()
{
  STEP="$1"
  STEP_START_EPOCH=$(date +%s)
  echo
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo "       - Step (start)  : $STEP"
  echo "       - Started at    : $(date)"
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo
}
endStep()
{
  STEP_END_EPOCH=$(date +%s)
  all_secs2=$(expr $STEP_END_EPOCH - $STEP_START_EPOCH)
  mins2=$(expr $all_secs2 / 60)
  secs2=$(expr $all_secs2 % 60 | awk '{printf("%02d",$0)}')
  echo
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
  echo "       - Step (end)    : $STEP"
  echo "       - Ended at      : $(date)"
  echo "       - Duration      : ${mins2}:${secs2}"
  echo "       - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - "
}
secondsToTime() {
  local total_seconds=$1

  local hours=$((total_seconds / 3600))
  local minutes=$(( (total_seconds % 3600) / 60 ))
  local seconds=$((total_seconds % 60))

  printf "%4s:%02d:%02d" $hours $minutes $seconds 
}
die()
{
  [ "$START_INTERM_EPOCH" != "" ] && endRun
  echo "
ERROR :
  $*"

  rm -f $PID_FILE

  exit 1
}
exec_sql()
{
#
#  Don't forget to use : set -o pipefail un the main program to have error managempent
#
  local VERBOSE=N
  local SILENT=N
  if [ "$1" = "-silent" ]
  then 
    SILENT=Y
    shift
  fi
  if [ "$1" = "-no_error" ]
  then
    err_mgmt="whenever sqlerror continue"
    shift
  else
    err_mgmt="whenever sqlerror exit failure"
  fi
  if [ "$1" = "-verbose" ]
  then
    VERBOSE=Y
    shift
  fi
  local login="$1"
  local stmt="$2"
  local lib="$3"
  local bloc_sql="$err_mgmt
set recsep off
set head off 
set feed off
set pages 0
set lines 2000
connect ${login}
$stmt"
  REDIR_FILE=""
  REDIR_FILE=$(mktemp)
  if [ "$lib" != "" ] 
  then
     printf "%-75s : " "$lib";
     sqlplus -s /nolog >$REDIR_FILE 2>&1 <<%EOF%
$bloc_sql
%EOF%
    status=$?
  else
     sqlplus -s /nolog <<%EOF% | tee $REDIR_FILE  
$bloc_sql
%EOF%
    status=$?
  fi
  if [ $status -eq 0 -a "$(egrep "SP2-" $REDIR_FILE)" != "" ]
  then
    status=1
  fi
  if [ "$lib" != "" ]
  then
    [ $status -ne 0 ] && { echo "*** ERREUR ***" ; test -f $REDIR_FILE && cat $REDIR_FILE ; rm -f $REDIR_FILE ; } \
                      || { echo "OK" ; [ "$VERBOSE" = "Y" ] && test -f $REDIR_FILE && sed -e "s;^;    > ;" $REDIR_FILE ; }
  fi 
  rm -f $REDIR_FILE
  [ $status -ne 0 ] && return 1
  return $status
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#  Usage
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
usage() 
{
 echo "$SCRIPT :

Usage :
 $SCRIPT [-n] [-h|-?]

      $SCRIPT_LIB

         -n           : Don't log the output to file
         -?|-h        : Help

  Version : $VERSION
  "
  exit
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.28.0/oci_cli_docs/index.html
prLine1()
{
    printf "${indent}+-%-15.15s-+-%-8.8s-+-%-30.30s-+-%-20.20s-+-%-30.30s-+-%-30.30s-+-%10.10s-+\n" \
    "---------------------------------------------------" \
    "---------------------------------------------------" \
    "---------------------------------------------------" \
    "---------------------------------------------------" \
    "---------------------------------------------------" \
    "---------------------------------------------------" \
    "---------------------------------------------------" 
}
backupAnalysis()
{
  local dOCID="$1"
  local indent="$2"
  local line=""
  echo
  prLine1
    printf "${indent}| %-15.15s | %-8.8s | %-30.30s | %-20.20s | %-30.30s | %-30.30s | %10.10s |\n" \
    "Type" \
    "State" \
    "Name" \
    "DB size" \
    "Start" \
    "End" \
    "Duration"
  prLine1
  oci db backup list --database-id="$dOCID" | jq --raw-output '.data[] |
.type
+";"+."lifecycle-state"
+";"+."display-name"
+";"+(."database-size-in-gbs" | tostring)
+";"+."time-started"
+";"+."time-ended"
' | while read line
  do
    # echo "$line"
    epoch_start=$(date -d "$(echo "$line" | cut -f5 -d";")" +"%s")
    epoch_end=$(date -d "$(echo "$line" | cut -f6 -d";")" +"%s")
    duration=$(secondsToTime $(($epoch_end - $epoch_start)))
    printf "${indent}| %-15.15s | %-8.8s | %-30.30s | %-20.20s | %-30.30s | %-30.30s | %10.10s |\n" \
      "$(echo "$line" | cut -f1 -d";")" \
      "$(echo "$line" | cut -f2 -d";")" \
      "$(echo "$line" | cut -f3 -d";")" \
      "$(echo "$line" | cut -f4 -d";")" \
      "$(date -d "$(echo "$line" | cut -f5 -d";")" +"%a %d/%m/%Y %H:%M:%S %Z")" \
      "$(date -d "$(echo "$line" | cut -f6 -d";")" +"%a %d/%m/%Y %H:%M:%S %Z")" \
      $duration
  done 
  prLine1
}
databasesAnalysis()
{
  local cOCID="$1"
  local eOCID="$2"
  local indent="$3"
  local line=""
  
  oci db database list --vm-cluster-id="$eOCID" --compartment-id="$cOCID" | jq --raw-output '.data[] |
.id 
+";"+."db-name" 
+";"+."db-unique-name" 
+";"+(."db-backup-config"."auto-backup-enabled" | tostring )
+";"+."db-home-id" 
' | while read line                        
  do
    dOCID=$(echo $line | cut -f1 -d";")
    hOCID=$(echo $line | cut -f5 -d";")
    version=$(oci db db-home get --db-home-id="$hOCID" | jq --raw-output '.data."db-version"')
    echo
    echo   "${indent}- DB      : $(echo $line | cut -f2 -d";") / $(echo $line | cut -f3 -d";")"
    echo   "${indent}  OCID    : $dOCID"
    echo
    printf "${indent}           Auto backup       : %-10.10s Version           : %-10.10s \n" \
           $(echo $line | cut -f4 -d";") \
           $version
           
    backupAnalysis "$dOCID" "${indent}    "
    
  done
}

vmClustersAnalysis()
{
  local cOCID="$1"
  local indent="$2"
  local line=""

  oci db cloud-vm-cluster list --compartment-id="$cOCID" | jq --raw-output '.data[] | 
.id
+";"+(."cpu-core-count" | tostring)
+";"+."display-name"
+";"+."gi-version"
+";"+."hostname"
+";"+."shape"
+";"+(."storage-size-in-gbs" | tostring)
+";"+."cluster-name"
' | while read line
  do
    eOCID=$(echo $line | cut -f1 -d";")
    echo   "${indent}  . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . ."
    echo   "${indent}- EXADATA : $(echo $line | cut -f3 -d";") / $(echo $line | cut -f5 -d";")"
    echo   "${indent}  OCID    : $eOCID"
    echo
    printf "${indent}           Cpus              : %-10.10s Storage           : %-10.10s GI Vers           : %-10.10s \n" \
           $(echo $line | cut -f2 -d";") \
           $(echo $line | cut -f7 -d";") \
           $(echo $line | cut -f4 -d";") 
    printf "${indent}           Shape             : %-20.20s Cluster : %-20.20s \n" \
           $(echo $line | cut -f6 -d";") \
           $(echo $line | cut -f8 -d";") 
    echo   "${indent}  . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . ."
    echo
    databasesAnalysis "$cOCID" "$eOCID" "${indent}    "
  done
}
compartmentAnalysis()
{
  local parent="$1"
  local indent="$2"
  local cOCID=""
  local cName=""
  local cDescription=""
  local line=""
  
  oci iam compartment list --compartment-id="$parent" | jq --raw-output '.data[] | .id +";"+ .name +";"+ .description' | while read line
  do
    cOCID=$(echo $line | cut -f1 -d";")
    cName=$(echo $line | cut -f2 -d";")
    cDescription=$(echo $line | cut -f3 -d";")
    
    echo "${indent}========================================================="
    echo "${indent}- Compartment   : $cName/$cDescription"
    echo "${indent}- OCID          : $cOCID"
    echo "${indent}========================================================="
    echo
    
    compartmentAnalysis "$cOCID" "${indent}    "
  done
  vmClustersAnalysis "$parent" "${indent}    "
}


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

set -o pipefail

#if tty -s
if false
then
  die "Please run this script in nohup mode"
fi


set -o pipefail

SCRIPT=$(basename $0)
SCRIPT_BASE=$(basename $SCRIPT .sh)

SCRIPT_LIB="EXADATA Databases backup summary"

#[ "$(id -un)" != "oracle" ] && die "Merci de lancer ce script depuis l'utilisateur \"oracle\""
#[ "$(hostname -s | sed -e "s;.*\([0-9]\)$;\1;")" != "1" ] && die "Lancer ce script depuis le premier noeud du cluster"

# [ "$1" = "" ] && usage

toShift=0
while getopts nh opt
do
  case $opt in
   # --------- Source Database --------------------------------
   # --------- Target Database --------------------------------
   # --------- Modes de fonctionnement ------------------------
   # --------- Usage ------------------------------------------
   n)   logOutput=NO   ; toShift=$(($toShift + 1)) ;;
   ?|h) usage "Help requested";;
  esac
done
shift $toShift 
# -----------------------------------------------------------------------------
#
#       Analyse des paramètres et valeurs par défaut
#
# -----------------------------------------------------------------------------

LOG_DIR=$HOME/scriptsLOG/$SCRIPT_BASE
LOG_FILE=$LOG_DIR/${SCRIPT_BASE}_$(date +%Y%m%d_%H%M%S).log
[ "$logOutput" = "NO" ] && LOG_FILE=/dev/null

[ "$LOG_FILE" != "" -a "$LOG_FILE" != "/dev/null" ] && mkdir -p $LOG_DIR

[ "$OCI_CONFIG_FILE" = "" ] && OCI_CONFIG_FILE=$HOME/.oci/config
[ ! -f $OCI_CONFIG_FILE ] && die "UNable to find OCICLI config file"


{
  tenantOCID=$(grep tenancy= $OCI_CONFIG_FILE | cut -f2 -d "=")
  l=$(oci iam tenancy get --tenancy-id=$tenantOCID | jq --raw-output '.data | .name + ";" + .description')
  startRun "$SCRIPT_LIB"

  tenantName=$(echo $l | cut -f1 -d ";")
  tenantDescription=$(echo $l | cut -f2 -d ";")

  echo
  echo "        Tenancy          : $tenantName"
  echo "        Description      : $tenantDescription"
  echo
  
  # backupAnalysis "ocid1.database.oc1.eu-paris-1.anrwiljrrk7elwaaz74676tdwl2dre7dmvmw5nytgcn7goczozs4s5ra62ma" "xxx"
  # vmClustersAnalysis "ocid1.compartment.oc1..aaaaaaaa4mmprxwklhghddbijgsf3b4dy5icvrcxj5acvidhmqbl7jvqkmnq" "    "
  # compartmentAnalysis "$tenantOCID" "    "
  compartmentAnalysis "$tenantOCID" "    "

  
  endRun
} | tee $LOG_FILE

