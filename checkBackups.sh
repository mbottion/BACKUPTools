egrep -v "^#|^ *$" /etc/oratab | cut -f1 -d":" | cut -f1 -d"_" | while read db
do
  echo
  echo "=================================="
  echo "DB : $db (failed backups)"
  echo "=================================="
  echo
  /var/opt/oracle/bkup_api/bkup_api list jobs --dbname=$db | egrep "DBaaS|^UUID|Action *:|failed|logfile *:"
done
