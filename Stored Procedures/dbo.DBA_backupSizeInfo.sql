SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
--=============================================
-- Copyright (C) 2018 Raul Gonzalez, @SQLDoubleG
-- All rights reserved.
--   
-- You may alter this code for your own *non-commercial* purposes. You may
-- republish altered code as long as you give due credit.
--   
-- THIS CODE AND INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF 
-- ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED 
-- TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
-- PARTICULAR PURPOSE.
--
-- =============================================
-- Author:		Raul Gonzalez
-- Create date: 16/05/2013
-- Description:	Returns useful info about a number of last backup(s)
--				for a given database or all if not specified
--
-- Parameters:
--				@dbname
--				@onlyFullBkp, set to 1 to display only full backups, if set to 0, will display any backup
--				@numBkp, specify the number of backups to display per database (from newest to oldest)
--
-- Log History:	25/09/2013 RAG	- Changed the query to display backups distributed in more than 1 file as 1 single backup
--									and physical_device_name will concatenate all files for that backup
--				19/12/2013 RAG	- Changed to use LIKE in the databases query to use wildcards in the parameter
--				04/08/2014 RAG	- Added a basic restore statement
--				26/04/2016 RAG	- Changed parameter @onlyFullBkp for @backupType
--				10/10/2018 RAG	- Added backup type X that will all types expect LOG backups
--				14/10/2018 RAG	- Modified the restore command to consider RESTORE LOG 
-- 								- Modified the restore command to be by default WITH NORECOVERY
--								- Added @orderBy to sort ascending or descending to allow copy paste 
-- 									the restore commands in the right order
--								- Changed order of the returned columns to have finished date at first glance
--				16/10/2018 RAG	- Changed the behaviour of @orderBy so it will affect the final resultset which will be
-- 									always the newest TOP (@numBkp) rows
--
-- =============================================
CREATE PROCEDURE [dbo].[DBA_backupSizeInfo]
	@dbname			SYSNAME = NULL
	, @backupType	CHAR(1) = NULL
	, @numBkp		INT = 1
	, @orderBy		VARCHAR(10) = 'DESC'
AS
BEGIN
			
	SET NOCOUNT ON

	SET @numBkp		= ISNULL(@numBkp, 1) 
	SET @orderBy	= ISNULL(@orderBy, 'DESC') 

	IF @backupType IS NOT NULL AND @backupType NOT IN ('D', 'I', 'L', 'F', 'G', 'P', 'Q', 'X') BEGIN
		RAISERROR ('The parameter @backupType can only be one of these values
D-> Database
I-> Differential database
L-> Log
F-> File or filegroup
G-> Differential file
P-> Partial
Q-> Differential partial
X-> All types except LOG
NULL -> All types will be included', 16, 0) WITH NOWAIT
		RETURN -100
	END

	IF @orderBy NOT IN ('ASC', 'DESC') BEGIN
		RAISERROR ('The parameter @orderBy can only be one of these values
	ASC-> To sort by date asceding
	DESC-> To sort by date asceding', 16, 0) WITH NOWAIT
		RETURN -200
	END

	;WITH cte AS (
		SELECT	b.server_name
				, b.database_name
				, b.type
				,	CASE 
						WHEN b.type = 'D' THEN 'Database'
						WHEN b.type = 'I' THEN 'Differential database'
						WHEN b.type = 'L' THEN 'Log'
						WHEN b.type = 'F' THEN 'File or filegroup'
						WHEN b.type = 'G' THEN 'Differential file'
						WHEN b.type = 'P' THEN 'Partial'
						WHEN b.type = 'Q' THEN 'Differential partial'
					END AS backup_type
				, b.backup_size
				, b.has_backup_checksums
				, b.compressed_backup_size 
				, b.backup_start_date
				, b.backup_finish_date
				, b.media_set_id
				--, mf.physical_device_name
				, ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_set_id DESC) AS RowNum			
			FROM msdb.dbo.backupset as b
				--INNER JOIN msdb.dbo.backupmediafamily as mf
				--	ON mf.media_set_id = b.media_set_id
			WHERE database_name LIKE ISNULL(@dbname, database_name)
				AND b.server_name = @@SERVERNAME
				AND (type = ISNULL(@backupType, type) OR (@backupType = 'X' AND type <> 'L'))
	)

	SELECT 	server_name
			, database_name
			, backup_type
			, CONVERT(DATETIME2(0), backup_finish_date) AS backup_finish_date
			, STUFF((SELECT ', ' + physical_device_name FROM msdb.dbo.backupmediafamily as mf WHERE mf.media_set_id = cte.media_set_id FOR XML PATH('')), 1,2,'' ) AS physical_device_name
			, CONVERT(INT, backup_size / 1024 /1024 ) AS size_MB
			, CONVERT(INT, compressed_backup_size / 1024 /1024 ) AS compressed_size_MB
			, CONVERT(DECIMAL(10,2), backup_size / 1024. /1024 /1024 ) AS size_GB
			, CONVERT(DECIMAL(10,2), compressed_backup_size / 1024. / 1024 /1024 ) AS compressed_size_GB
			, CONVERT(DECIMAL(10,2), 100 - ( ( compressed_backup_size * 100 ) / backup_size ) ) AS compression_ratio
			, CONVERT(DECIMAL(10,2), (compressed_backup_size / 1024. / 1024) / (DATEDIFF(SECOND, backup_start_date, backup_finish_date ) + 1) ) AS MB_per_sec
			, dbo.formatSecondsToHR( DATEDIFF(SECOND,backup_start_date, backup_finish_date) ) AS duration
			, CASE WHEN has_backup_checksums = 1 THEN 'Yes' ELSE 'No' END AS has_backup_checksums
			, 'RESTORE ' + CASE WHEN type = 'L' THEN 'LOG ' ELSE 'DATABASE ' END + QUOTENAME(database_name) + CHAR(10) + CHAR(9) + 'FROM ' + 
				STUFF( (SELECT ', DISK = ''' + physical_device_name + '''' + CHAR(10) + CHAR(9)
							FROM msdb.dbo.backupmediafamily as mf WHERE mf.media_set_id = cte.media_set_id FOR XML PATH('')), 1,2,'' ) + 'WITH NORECOVERY' AS RESTORE_BACKUP
		FROM cte
		WHERE RowNum <= @numBkp
		ORDER BY database_name ASC
			-- RowNum is descending, so we need to invert the order, this is not a mistake!
			, CASE WHEN @orderBy = 'ASC' THEN RowNum ELSE NULL END DESC
			, CASE WHEN @orderBy = 'DESC' THEN RowNum ELSE NULL END ASC 
	END
GO
