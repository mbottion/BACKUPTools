VERSION=1.0
_____________________________TraceFormating() { : ;}
secs2HMS()
{
  local secs=$1
  local h=$(( $secs / 3600))
  local r=$(( $secs % 3600 ))
  local m=$(( $r / 60))
  local s=$(( $r % 60))
  printf "%4d:%02d:%02d" $h $m $s
}
libAction()
{
  local mess="$1"
  local indent="$2"
  [ "$indent" = "" ] && indent="  - "
  printf "%-90.90s : " "${indent}${mess}"
}
infoAction()
{
  local mess="$1"
  local indent="$2"
  [ "$indent" = "" ] && indent="  - "
  printf "%-s\n" "${indent}${mess}"
}
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
  if [ "$CMD_FILE" != "" ]
  then
    echo   "Commands Logged to : $CMD_FILE"
    echo   "========================================================================================"
  fi
  rm -f /tmp/${SCRIPT}*.tmp*
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
die()
{
  [ "$START_INTERM_EPOCH" != "" ] && endRun
  echo "
ERROR :
  $*"

  rm -f $PID_FILE

  exit 1
}
_____________________________Environment() { : ;}
setDbEnv()
{
  libAction "Set $1 environment"
  . $HOME/$1.env && echo OK || { echo ERROR ; die "Unable to set database envirronment" ; } 
}
_____________________________Utilities() { : ;}
getPassDB()
{
  local dir=""
  if [ -d /acfs01/dbaas_acfs/$ORACLE_UNQNAME/db_wallet ]
  then
    dir=/acfs01/dbaas_acfs/$ORACLE_UNQNAME/db_wallet
  elif [ -d /acfs01/dbaas_acfs/$ORACLE_SID/db_wallet ]
  then
    dir=/acfs01/dbaas_acfs/$ORACLE_SID/db_wallet
  elif [ -d /acfs01/dbaas_acfs/$(echo $ORACLE_SID|sed -e "s;.$;;")/db_wallet ]
  then
    dir=/acfs01/dbaas_acfs/$(echo $ORACLE_SID|sed -e "s;.$;;")/db_wallet
  else
    echo
  fi
  mkstore -wrl $dir -viewEntry passwd | grep passwd | sed -e "s;^ *passwd = ;;"
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
  local loginSecret=$(echo "$login" | sed -e "s;/[^@ ]*;/SecretPasswordToChange;" -e "s;^/SecretPasswordToChange;/;")
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
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
SQLPLUS : ${lib:-No description}
===============================================================================
sqlplus \"$loginSecret\" <<%%
$bloc_sql
%%
    " >> $CMD_FILE
  fi
  REDIR_FILE=""
  REDIR_FILE=$(mktemp)
  if [ "$lib" != "" ] 
  then
     libAction "$lib"
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
exec_rman()
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
  if [ "$1" = "-verbose" ]
  then
    VERBOSE=Y
    shift
  fi
  local login="$1"
  local loginSecret=$(echo "$login" | sed -e "s;/[^@ ]*;/SecretPasswordToChange;" -e "s;^/SecretPasswordToChange;/;")
  local stmt="$2"
  local lib="$3"
  local bloc_sql="
$stmt"
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
RMAN : ${lib:-No description}
===============================================================================
rman \"$loginSecret\" <<%%
$bloc_sql
%%
    " >> $CMD_FILE
  fi
  REDIR_FILE=""
  REDIR_FILE=$(mktemp)
  if [ "$lib" != "" ] 
  then
     libAction "$lib"
     rman $login >$REDIR_FILE 2>&1 <<%EOF%
$bloc_sql
%EOF%
    status=$?
  else
     rman $login <<%EOF% | tee $REDIR_FILE  
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
exec_srvctl()
{
  SILENT=N
  [ "$1" = "-silent" ] &&  { local SILENT=Y ; shift ; }
  local cmd=$1
  local lib=$2
  local okMessage=$3
  local koMessage=$4
  local dieMessage=$5
  local tmpOut=${TMPDIR:-/tmp}/$$.tmp
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
SRVCTL : ${lib:-No description}
===============================================================================
srvctl $cmd
    " >> $CMD_FILE
  fi
  [ "$lib" != "" ] &&  libAction "$lib"
  if srvctl $cmd > $tmpOut 2>&1
  then
    [ "$lib" != "" ] && echo "${okMessage:-OK}"
    [ "$lib" = "" ]  && cat "$tmpOut"
    rm -f "$tmpOut"
    return 0
  else
    [ "$lib" != "" ] && echo "${koMessage:-ERROR}"
    [ "$SILENT" = "N" ] && cat $tmpOut
    rm -f $tmpOut
    [ "$diemessage" = "" ] && return 1 || die "$dieMessage"
  fi
}
exec_dgmgrl()
{
  if [ "$3" != "" ]
  then
    local connect="$1"
    shift
  else
    local connect="sys/${dbPassword}@${primDbUniqueName}"
  fi
  local connectSecret=$(echo "$connect" | sed -e "s;/[^@ ]*;/SecretPasswordToChange;" -e "s;^/SecretPasswordToChange;/;")
  local cmd=$1
  local lib=$2
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
DGMGRL : ${lib:-No description}
===============================================================================
dgmgrl -silent \"$connectSecret\" \"$cmd\"
    " >> $CMD_FILE
  fi
  # echo "    - $cmd"
  [ "$lib" != "" ] && libAction "$lib"
  dgmgrl -silent "$connect" "$cmd" > $$.tmp 2>&1 \
    && { [ "$lib" != "" ] && echo "OK" ; [ "$lib" = "" ] && cat $$.tmp ; rm -f $$.tmp ; return 0 ; } \
    || { [ "$lib" != "" ] && echo "ERROR" ; cat $$.tmp ; rm -f $$.tmp ; return 1 ; }
}
exec_asmcmd()
{
  local cmd=$1
  local lib=$2
  local okMessage=${3:-OK}
  local koMessage=${4:-ERROR}
  local dieMessage=$5
  local tmpOut=${TMPDIR:-/tmp}/$$.tmp
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
ASMCMD : ${lib:-No description}
===============================================================================
asmcmd --privilege sysdba $cmd
    " >> $CMD_FILE
  fi

  libAction "$lib"
  if asmcmd --privilege sysdba $cmd > $tmpOut 2>&1
  then
    echo "$okMessage"
    rm -f $tmpOut
    return 0
  else
    echo "$koMessage"
    cat $tmpOut
    rm -f $tmpOut
    [ "$diemessage" = "" ] && return 1 || die "$dieMessage"
  fi
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
createASMDir()
{
  libAction "Creating $1" "    - "
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
ASMCMD : Creating $1 If non existent
===============================================================================
asmcmd --privilege sysdba mkdir $1
    " >> $CMD_FILE
  fi
  if [ "$(asmcmd --privilege sysdba ls -ld $1)" = "" ] 
  then
    asmcmd --privilege sysdba mkdir $1 > $TMP1 2>&1 \
                && { echo "OK" ; rm -f $TMP1 ; } \
                || { echo "ERROR" ; cat $TMP1 ; rm -f $TMP1 ; die "Unable to create $1" ; }
  else
    echo "Exists"
  fi
}
removeASMDir()
{
  libAction "Removing ASM Folder $1" "    - "
  if [ "$CMD_FILE" != "" ]
  then
    echo "\
===============================================================================
ASMCMD : Removing ASM Folder $1
===============================================================================
asmcmd --privilege sysdba rm -rf $1
    " >> $CMD_FILE
  fi
  if [ "$(asmcmd --privilege sysdba ls -ld $1 2>/dev/null)" != "" ] 
  then
    asmcmd --privilege sysdba rm -rf $1 > $TMP1 2>&1 \
                && { echo "OK" ; rm -f $TMP1 ; } \
                || { echo "ERROR" ; cat $TMP1 ; rm -f $TMP1 ; die "Unable to remove $1" ; }
  else
    echo "Not exists"
  fi
}
getSecretPassword()
{
  touch $HOME/passwords.txt
  sed -i "/$1/ h" $HOME/passwords.txt
  echo "CODE=$1PASSWD=Wel_Come_12" >> $HOME/passwords.txt
  echo "Wel_Come_12"
}
#
# #################################################################################
#
#     This script create a database on the current ORACLE_HOME, the HOME must have
#  been previously deployed on the machine.
#
#    The databse in encrypted with an auto-login wallet. THis can be changed later if
#  needed. 
#   
#    If the tool is installed at a cusomer without ASO option, simply remove the encription part
#  of the script
#
# #################################################################################
#
_____________________________TraceFormating() { : ;}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#  Usage
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
usage() 
{
 echo "$SCRIPT :

Usage :
 $SCRIPT [-d DB_NAME] [-n] [-h|-?]

      $SCRIPT_LIB
         
         -d NAME      : DATABASE Name
         -n           : Don't log the output to file
         -?|-h        : Help

  Version : $VERSION
  "
  exit
}
_____________________________Environment() { : ;}
showEnv()
{
echo "

   Environment variable used :
   =========================

   ORACLE_HOME      : $ORACLE_HOME
   ORACLE_BASE      : $ORACLE_BASE
   ORACLE_SID       : $ORACLE_SID
   
"
}

#
#      SOurce the utilities script, in the same folder
#
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -o pipefail

INDENT1="    - "
INDENT2="      - "
INDENT3="        - "
INDENT4="          - "

_____________________________main() { : ; }

#if tty -s
if false
then
  die "Please run this script in nohup mode"
fi


SCRIPT=$(basename $0)
SCRIPT_BASE=$(basename $SCRIPT .sh)
SCRIPT_LIB="Migration Factory 2.0 : ORACLE Database Backup"
TMPFILE1=/tmp/${SCRIPT}.$$.tmp1

runUser=oracle
[ "$(id -un)" != "$runUser" ] && die "This script must be launched by the  \"$runUser\""
#[ "$(hostname -s | sed -e "s;.*\([0-9]\)$;\1;")" != "1" ] && die "Lancer ce script depuis le premier noeud du cluster"

#
#    Default values
#

DBNAME=MFCDB

#
#       Parameter analysis
#
toShift=0
while getopts :d:nh opt
do
  case $opt in
   # --------- Folders --------------------------------
   # --------- Target Database --------------------------------
   d) DBNAME=$OPTARG ; toShift=$(($toShift + 2)) ;;
   # --------- Modes de fonctionnement ------------------------
   # --------- Usage ------------------------------------------
   n)   logOutput=NO   ; toShift=$(($toShift + 1)) ;;
   ?|h) usage "Help requested";;
  esac
done
shift $toShift 

#
#    Dependent variables
#
DB_DIR=/databases
LOG_DIR=$HOME/scriptsLOG/$SCRIPT_BASE/
LOG_FILE=$LOG_DIR/${SCRIPT_BASE}_$(date +%Y%m%d_%H%M%S).log
BACKUP_DIR=/mnt/mbottion-FSS1/BACKUP_DB/$DBNAME
mkdir -p $BACKUP_DIR || die "Unable to creat the backup DIR"
#CMD_FILE=$LOG_DIR/${SCRIPT_BASE}_$(date +%Y%m%d_%H%M%S).cmd

[ "$logOutput" = "NO" ] && LOG_FILE=/dev/null

[ "$LOG_FILE" != "" -a "$LOG_FILE" != "/dev/null" ] && mkdir -p $LOG_DIR


{
  unset ORACLE_PDB_SID
  startRun "$SCRIPT_LIB"

  showEnv

  export ORACLE_SID=$DBNAME

  startStep "Verifications"

  libAction "Check for existant ORACLE_HOME" "$INDENT1"
  [ -d $ORACLE_HOME ] || { echo "Not Exists" ; die "$ORACLE_HOME does not exists" ; } && echo Exists
  libAction "Check for database existence in oratab" "$INDENT1"
  [ "$(grep "^ *${ORACLE_SID}:" /etc/oratab)" = "" ] && { echo "Not Exists" ; die "Database $DBNAME already exists" ; } \
                                                      || echo Yes

  endStep


  startStep "Backup database"
  exec_rman "target /" "
configure retention policy to recovery window of 30 days;
CONFIGURE ARCHIVELOG DELETION POLICY TO BACKED UP 2 TIMES TO DISK;" "Configure RMAN"

  exec_rman "target /" "
sql 'alter system archive log current';
sql \"alter session set nls_date_format=''dd.mm.yyyy hh24:mi:ss''\";
RUN
{
configure controlfile autobackup on;
set command id to '${DBNAME}OnlineBackupFull';
ALLOCATE CHANNEL c1 DEVICE TYPE disk;
ALLOCATE CHANNEL c2 DEVICE TYPE disk;
ALLOCATE CHANNEL c3 DEVICE TYPE disk;
ALLOCATE CHANNEL c4 DEVICE TYPE disk;
backup AS COMPRESSED BACKUPSET full database tag ${DBNAME}_FULL format '$BACKUP_DIR/%d_%T_%s_%p_FULL' ;
sql 'alter system archive log current';
backup tag ${DBNAME}_ARCHIVE format '$BACKUP_DIR/%d_%T_%s_%p_ARCHIVE' archivelog all delete all input ;
backup tag ${DBNAME}_CONTROL current controlfile format '$BACKUP_DIR/%d_%T_%s_%p_CONTROL';
release channel c1;
release channel c2;
release channel c3;
release channel c4;
}" "Database $DBNAME full Backup"|| die "Backup Error"
  exec_sql "/ as sysdba" "start $SCRIPT_DIR/listBackups.sql ALL NO"
  endStep

  endRun
} | tee $LOG_FILE
finalStatus=$?
echo
echo "Cleaning LOGS"
echo "============="
echo
LOGS_TO_KEEP=10
i=0
ls -1t $LOG_DIR/*.log 2>/dev/null | while read f
do
  i=$(($i + 1))
  [ $i -gt $LOGS_TO_KEEP ] && { echo "  - Removing $f" ; rm -f $f ; }
done
i=0
ls -1t $LOG_DIR/*.cmd 2>/dev/null | while read f
do
  i=$(($i + 1))
  [ $i -gt $LOGS_TO_KEEP ] && { echo "  - Removing $f" ; rm -f $f ; }
done

exit $finalStatus

