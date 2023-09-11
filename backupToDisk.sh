
rman target /
sql 'alter system archive log current';
sql "alter session set nls_date_format=''dd.mm.yyyy hh24:mi:ss''";
RUN
{
configure controlfile autobackup on;
set command id to 'ORCLOnlineBackupFull';
ALLOCATE CHANNEL c1 DEVICE TYPE disk;
ALLOCATE CHANNEL c2 DEVICE TYPE disk;
ALLOCATE CHANNEL c3 DEVICE TYPE disk;
ALLOCATE CHANNEL c4 DEVICE TYPE disk;
backup AS COMPRESSED BACKUPSET full database tag ORCL_FULL format '/opt/oracle/backups/ORCL/%d_%T_%s_%p_FULL' ;
sql 'alter system archive log current';
backup tag ORCL_ARCHIVE format '/opt/oracle/backups/ORCL/%d_%T_%s_%p_ARCHIVE' archivelog all delete all input ;
backup tag ORCL_CONTROL current controlfile format '/opt/oracle/backups/ORCL/%d_%T_%s_%p_CONTROL';
release channel c1;
release channel c2;
release channel c3;
release channel c4;
}
