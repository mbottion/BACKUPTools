set serveroutput on
begin
  if (upper('&1') in ('USAGE','HELP','-?','-H'))
  then
    raise_application_error(-20000,'
+---------------------------------------------------------------------------------------
| Usage:
|    listBackups.sql [what] [files]    
|   
|   ACCENTURE''s request to sho batch progress
|
|   Parameters :
|       what     : What kind of backups ALL|DB|AL                      - Default : DB
|       files    : Show backup sets YES|NO                             - Default : NO
|       
+---------------------------------------------------------------------------------------
       ');
  end if ;
end ;
/
-- -----------------------------------------------------------------
-- Parameters
-- -----------------------------------------------------------------

define  what="case when '&1' is null then 'DB' else upper('&1') end" 
define files="case when '&2' is null then 'NO' else upper('&2') end" 


column tag             format a35
column backup_type     format a20
column Status          format a3
column info            format a150
column start_time      format a20
column completion_time format a20
column mb_in           format a15
column mb_out          format a15
column mb_sec          format a10


WITH backups AS (
  SELECT
    DECODE( s.backup_type,'I','INCREMENTAL Level ' || s.incremental_level,'L','Archivelog',s.backup_type ) backup_type
   ,round( SUM( s.original_input_bytes ) / 1024 / 1024,2 ) mb_in
   ,round( SUM( s.output_bytes ) / 1024 / 1024,2 ) mb_out
   ,s.status
   ,MIN( s.start_time ) start_time
   ,MAX( s.completion_time ) completion_time
   ,round( ( SUM( s.output_bytes ) / 1024 / 1024 ) / ( ( MAX( s.completion_time ) - MIN( s.start_time ) ) * 86400 ),1 ) mb_sec
   ,f.tag
   ,f2.max_bs_key bs_key
  FROM
    v$backup_set_details s
    JOIN (
      SELECT DISTINCT
        bs_key
       ,tag
      FROM
        v$backup_files
    ) f
    ON ( s.bs_key   = f.bs_key
         AND tag IS NOT NULL )
    JOIN (
      SELECT 
        max(bs_key) max_bs_key
       ,tag
      FROM
        v$backup_files
      group by tag
    ) f2
    ON ( f.tag   = f2.tag)
  GROUP BY
    s.backup_type
   ,s.incremental_level
   ,s.status
   ,f.tag
   ,f2.max_bs_key
),backup_sets AS (
  SELECT
    DECODE( backup_type,'I','INCREMENTAL Level ' || incremental_level,'L','Archivelog',backup_type ) backup_type
   ,round( original_input_bytes / 1024 / 1024,2 ) mb_in
   ,round( output_bytes / 1024 / 1024,2 ) mb_out
   ,status
   ,start_time
   ,completion_time
   ,round( ( output_bytes / 1024 / 1024 ) / ( ( completion_time - start_time ) * 86400 ),1 ) mb_sec
   ,session_key
   ,session_stamp
   ,bs_key
   ,controlfile_included
   ,keep
  FROM
    v$backup_set_details
),backup_files AS (
  SELECT
    f.file_type
   ,f.bp_piece# piece_count
   ,case
     when f.file_type = 'ARCHIVED LOG' then
       'Thread: ' || f.rl_thread# || ' Sequence: ' || rl_sequence#
     else f.fname
    end fname
   ,f.tag
   ,f.bs_key
  FROM
    v$backup_files f
  WHERE
    f.file_type != 'PIECE'
  UNION
  SELECT
    *
  FROM
    (
      SELECT
        'PIECE (First)'
       ,max_piece 
       ,fp.fname
       ,f.tag  tag
       ,f.bs_key
      FROM
        (select 
           file_type
          ,bs_key
          ,min(bp_piece#) min_piece
          ,max(bp_piece#) max_piece
          , min(tag) tag 
        from v$backup_files
        GROUP BY
          file_type
         ,bs_key
        ) f
      join v$backup_files fp on ( fp.bs_key=f.bs_key and fp.file_type='PIECE' and fp.bp_piece# = min_piece)
      WHERE
        f.file_type   = 'PIECE'
    )
  UNION
  SELECT
    *
  FROM
    (
      SELECT
        'PIECE (Last)'
       ,max_piece 
       ,lp.fname
       ,f.tag  tag
       ,f.bs_key
      FROM
        (select 
           file_type
          ,bs_key
          ,min(bp_piece#) min_piece
          ,max(bp_piece#) max_piece
          , min(tag) tag 
        from v$backup_files
        GROUP BY
          file_type
         ,bs_key
        ) f
      join v$backup_files lp on ( lp.bs_key=f.bs_key and lp.file_type='PIECE' and lp.bp_piece# = max_piece)
      WHERE
        f.file_type   = 'PIECE'
        and max_piece != 1
    )
), result as (
SELECT
  tag
 ,backup_type
 ,status
 ,   '--+-> ' || rpad(to_char(start_time,'dd/mm/yyyy hh24:mi:ss'),20) || ' --> ' 
  || rpad(to_char(completion_time,'dd/mm/yyyy hh24:mi:ss'),20)
  || 'In MB: ' || rpad(ltrim(TO_CHAR( mb_in,'999G999G990D99' )),16)
  || 'Out MB: ' || rpad(ltrim(TO_CHAR( mb_out,'999G999G990D99' )),16)
  || 'MB/sec: ' || rpad(ltrim(TO_CHAR( mb_sec,'999G990D99' )),11)
  || 'Duration: ' || rpad(
                          regexp_replace(
                                         ltrim(
                                               numtodsinterval((completion_time-start_time),'DAY')
                                              )
                                        ,'^\+0* ([0-9:]*)\.[0-9]*$'
                                        ,'\1'
                                        )
                         ,15
                         )
  || '' info
 ,start_time
 ,completion_time
 ,TO_CHAR( mb_in,'999G999G990D99' ) mb_in
 ,TO_CHAR( mb_out,'999G999G990D99' ) mb_out
 ,TO_CHAR( mb_sec,'999G990D99' ) mb_sec
 ,bs_key bs_key
 ,NULL file_type
 ,NULL piece_count
 ,NULL
 ,NULL
 ,NULL
 ,10 ord
FROM
  backups
where
  backup_type like case &what
                     when 'DB'  then  'INCREMENTAL%'
                     when 'AL'  then  'Archive%'
                     when 'ALL' then  '%'
                   end 
UNION
SELECT
  null
 ,NULL
 ,NULL
 ,case f.file_type
  when 'PIECE (First)' then '  +--+--> Piece ' || rpad(1,4) || ' of ' || rpad(f.piece_count,4) || ': ' || f.fname
  when 'PIECE (Last)'  then '  |  +--> Piece ' || rpad(f.piece_count,4) || ' of ' || rpad(f.piece_count,4) || ': ' || f.fname
  when 'ARCHIVED LOG'  then '  |  +--+--> Archived LOG ' || f.fname
  when 'DATAFILE'      then '  |  +--+--> Datafile     ' || regexp_replace(f.fname,'^([^/]*/)(.*)(/[^/]*)(/[^/]*)$','\1 ... \4')
  else f.file_type
  end
  || ''
 ,start_time
 ,completion_time
 ,NULL
 ,NULL
 ,NULL
 ,f.bs_key
 ,f.file_type
 ,f.piece_count
 ,f.fname
 ,f.tag
 ,NULL
 ,20 ord
-- ,f.*
FROM
  backup_sets s
  JOIN backup_files f
  ON ( s.bs_key   = f.bs_key )
WHERE
  1   =  case &files 
           when 'YES' then 1
           when 'NO'  then 2
         end
ORDER BY
  bs_key DESC
 ,ord
)
select tag,backup_type,status,info from result
/

