function Get-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $InstanceName,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $FilePath,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $LogPath
    )
            
    $retVal = @{
        InstanceName = $InstanceName
        SqlAdministratorCredential = $SqlAdministratorCredential
        FilePath = $FilePath
        LogPath = $LogPath
    }

    $retVal
}

function Set-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $InstanceName,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $FilePath,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $LogPath
    )

    Remove-Module SQLPS
    Import-Module SQLPS -MinimumVersion 14.0

    try
    {
        Write-Verbose "Creating SMO Server Object"     

        # Get sql server instance
        $Server = Get-LocalSqlServer -Credential $SqlAdministratorCredential

        Write-Verbose "Setting SQL SERVER DATA/LOG folder"     
        # Setup file and log paths. If already set, then it is a no-op
        UpdateSqlServerFolders -FilePath $FilePath -LogPath $LogPath -Server $Server -Credential $SqlAdministratorCredential
        
        # Alter System database location
        Alter-SystemDatabaseLocation -FilePath $FilePath -LogPath $LogPath -ServiceCredential $SqlAdministratorCredential
         
        # Stop instance to apply configurations  
        Stop-SqlServer -InstanceName $InstanceName -Server $Server
        
        # Move system data base files to new location 
        Move-SystemDatabaseFile -FilePath $FilePath -LogPath $LogPath 
        
        # Start the instance
        Start-SqlServer -InstanceName $InstanceName -Server $Server

        Write-Verbose "Restarting SQL SERVER"     
    }
    catch
    {
        Write-Error "Error configuring SQL Server settings"
        throw $_
    }
}

function Test-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $InstanceName,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $FilePath,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $LogPath
    )

    $false
}

#Return a SMO object to a SQL Server instance using the provided credentials
function Get-LocalSqlServer
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]$Credential
    )

    $LoginCreataionRetry = 0

    While ($true) {
        
        try {
            #Setting Up Server Connection Object
            $sc = New-Object Microsoft.SqlServer.Management.Common.ServerConnection
            
            if ($Credential)
            {
                $sc.ConnectAsUser = $true

                #Can not find a proper documentation for setting ConnectTimeout to be forever so we use 300 seconds here which is the max time of the guest agent to determine timeout
                $sc.ConnectTimeout = 300
                
                if ($Credential.GetNetworkCredential().Domain -and ($Credential.GetNetworkCredential().Domain -ne $env:COMPUTERNAME))
                {
                    $domainCredential = "$($Credential.GetNetworkCredential().UserName)@$($Credential.GetNetworkCredential().Domain)"

                    Write-Verbose "Connecting Server with Domain Credential $($domainCredentia) "     

                    $sc.ConnectAsUserName = "$($Credential.GetNetworkCredential().UserName)@$($Credential.GetNetworkCredential().Domain)"
                }
                else
                {
                    Write-Verbose "Connecting Server with local Admin Credential $($Credential.GetNetworkCredential().UserName)"
                    
                    $sc.ConnectAsUserName = $Credential.GetNetworkCredential().UserName
                }
                
                $sc.ConnectAsUserPassword = $Credential.GetNetworkCredential().Password
            }
            else 
            {
               Throw "Server Connection Credential object is null, exiting ..."     
            }
            
            $s = New-Object Microsoft.SqlServer.Management.Smo.Server $sc 
            
            if ($s.Information.Version) {
            
                $s.Refresh()
            
                Write-Verbose "SQL Management Object Created Successfully, Version : '$($s.Information.Version)' "   
            
            }
            else
            {
                throw "SQL Management Object Creation Failed"
            }
            
            return $s

        }
        catch [System.Exception] 
        {
            $LoginCreationRetry = $LoginCreationRetry + 1
            
            if ($_.Exception.InnerException) {                   
             $ErrorMSG = "Error occured: '$($_.Exception.Message)',InnerException: '$($_.Exception.InnerException.Message)',  failed after '$($LoginCreationRetry)' times"
            } 
            else 
            {               
             $ErrorMSG = "Error occured: '$($_.Exception.Message)', failed after '$($LoginCreationRetry)' times"
            }
            
            if ($LoginCreationRetry -eq 15) 
            {
                Write-Verbose "Error occured: $ErrorMSG, reach the maximum re-try: '$($LoginCreationRetry)' times, exiting...."

                Throw $ErrorMSG
            }

            start-sleep -seconds 60

            Write-Verbose "Error occured: $ErrorMSG, retry for '$($LoginCreationRetry)' times"
        }
    }
}


#Create a folder
function CreateFolder([string]$folderPath)
{
    if ([System.IO.Directory]::Exists($folderPath))
    {
        Write-Verbose -Message "Folder '$($folderPath)' exists already, no need to create"

        return
    }
    
    Write-Verbose -Message "Creating folder '$($folderPath)' ..."

    [System.IO.Directory]::CreateDirectory($folderPath) | Out-Null
       
    if ([System.IO.Directory]::Exists($folderPath))
    {
      Write-Verbose -Message "Folder '$($folderPath)' Created Successfully!"
    }
    else 
    {
       throw  "Folder '$($folderPath)' creation failed!"
    }

}

#Sets the sql server object log and data paths folders
function UpdateSqlServerFolders([string]$FilePath, [string]$LogPath, [PSCredential]$Credential)
{

    if ($FilePath -and $LogPath)
    {   
        While ($true) {
            try {

                $Server = Get-LocalSqlServer -Credential $SqlAdministratorCredential

                Write-Verbose "Target File Path is $FilePath"
            
                Write-Verbose "Target Log Path is $LogPath"

                $currentFilePath = $Server.DefaultFile

                Write-Verbose "Current SQL Server Data Folder is $currentFilePath"

                $currentLogPath = $Server.DefaultLog

                Write-Verbose "Current SQL Server Log Folder is $currentLogPath"  
                
                CreateFolder -folderPath $FilePath

                CreateFolder -folderPath $LogPath

                $LoginCreationRetry = 0

                Write-Verbose -Message "Updating the server default file to '$($FilePath)'"

                Write-Verbose -Message "Updating the server default log to '$($LogPath)'"

                $Server.Settings.DefaultFile = $FilePath

                $Server.Settings.DefaultLog = $LogPath
                
                $Server.Settings.Alter()

                Write-Verbose -Message "The server default log path has been updated to '$($LogPath)'"

                Write-Verbose -Message "The server default file path has been updated to '$($FilePath)'"

                return $true
            }
            catch [System.Exception] 
            {
                $LoginCreationRetry = $LoginCreationRetry + 1
                
                if ($_.Exception.InnerException) {                   
                 $ErrorMSG = "Error occured: '$($_.Exception.Message)',InnerException: '$($_.Exception.InnerException.Message)',  failed after '$($LoginCreationRetry)' times"
                } 
                else 
                {               
                 $ErrorMSG = "Error occured: '$($_.Exception.Message)', failed after '$($LoginCreationRetry)' times"
                }

                if ($LoginCreationRetry -eq 5) 
                {
                    Write-Verbose "Error occured: $ErrorMSG, reach the maximum re-try: '$($LoginCreationRetry)' times, exiting...."

                    Throw $ErrorMSG
                }

                start-sleep -seconds 5

                Write-Verbose "Error occured: $ErrorMSG, retry for '$($LoginCreationRetry)' times"
            }
        }

    }
    else
    {
        throw "The the new FilePath or LogPath is Null, existing ....."
        
    }
}

#Start the sql server instance
function Start-SqlServer([string]$InstanceName, [Microsoft.SqlServer.Management.Smo.Server]$Server)
{
    $mc = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $Server.Name
    $list = $InstanceName.Split("\")
    if ($list.Count -gt 1)
    {
        $InstanceName = $list[1]
    }
    else
    {
        $InstanceName = "MSSQLSERVER"
    }
    $svc = $mc.Services[$InstanceName]

    Write-Verbose -Message "Starting SQL server instance '$($InstanceName)' ..."
    if ($svc.ServiceState -eq [Microsoft.SqlServer.Management.Smo.Wmi.ServiceState]::Stopped)
    {
        $svc.Start()
        while ($svc.ServiceState -ne [Microsoft.SqlServer.Management.Smo.Wmi.ServiceState]::Running)
        {
            $svc.Refresh()
        }
    }
}

#Stop the sql server instance
function Stop-SqlServer([string]$InstanceName, [Microsoft.SqlServer.Management.Smo.Server]$Server)
{
    $mc = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $Server.Name
    $list = $InstanceName.Split("\")
    if ($list.Count -gt 1)
    {
        $InstanceName = $list[1]
    }
    else
    {
        $InstanceName = "MSSQLSERVER"
    }
    $svc = $mc.Services[$InstanceName]

    Write-Verbose -Message "Stopping SQL server instance '$($InstanceName)' ..."
    $svc.Stop()
    $svc.Refresh()
    while ($svc.ServiceState -ne [Microsoft.SqlServer.Management.Smo.Wmi.ServiceState]::Stopped)
    {
        $svc.Refresh()
    }
}

#Restart the sql server instance
function Restart-SqlServer([string]$InstanceName, [Microsoft.SqlServer.Management.Smo.Server]$Server)
{
    Write-Verbose -Message "Restarting SQL server instance '$($InstanceName)' ..."

    Stop-SqlServer -InstanceName $InstanceName -Server $Server

    Start-SqlServer -InstanceName $InstanceName -Server $Server
}

function Alter-SystemDatabaseLocation([string]$FilePath, [string]$LogPath,[PSCredential]$ServiceCredential )
{
    Write-Verbose -Message "Granting $ServiceCredential.UserName full access permission to $FilePath and $LogPath"

    $permissionString = $ServiceCredential.UserName+":(OI)(CI)(F)"
    icacls $FilePath /grant $permissionString
    icacls $LogPath /grant $permissionString

    Write-Verbose -Message "Altering tempdb system database location setting to $FilePath\tempdb.mdf and $LogPath\templog.ldf"

    Invoke-Sqlcmd "Use master"
    Invoke-sqlCmd "ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILENAME = '$FilePath\tempdb.mdf');"
    Invoke-sqlCmd "ALTER DATABASE tempdb MODIFY FILE (NAME = templog, FILENAME = '$LogPath\templog.ldf');"

    Write-Verbose -Message "Altering model system database location setting to $FilePath\model.mdf and $LogPath\modellog.ldf"

    Invoke-sqlCmd "ALTER DATABASE model MODIFY FILE (NAME = modeldev, FILENAME = '$FilePath\model.mdf');"
    Invoke-sqlCmd "ALTER DATABASE model MODIFY FILE (NAME = modellog, FILENAME = '$LogPath\modellog.ldf');"

    Write-Verbose -Message "Altering msdb system database location setting to $FilePath\msdbdata.mdf and $LogPath\msdblog.ldf"

    Invoke-sqlCmd "ALTER DATABASE msdb MODIFY FILE (NAME = MSDBData, FILENAME = '$FilePath\msdbdata.mdf');"
    Invoke-sqlCmd "ALTER DATABASE msdb MODIFY FILE (NAME = MSDBLog, FILENAME = '$LogPath\msdblog.ldf');"

    Write-Verbose -Message "Altering master system database location setting to $FilePath\master.mdf , $LogPath\ERRORLOG and $LogPath\mastlog.ldf" 
        
    if  ([System.IO.Directory]::Exists("C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\DATA\"))
    {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg0 -Value "-dF:\DATA\master.mdf"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg1 -Value "-eF:\LOG\ERRORLOG"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg2 -Value "-lF:\LOG\mastlog.ldf"
    }
    elseif ([System.IO.Directory]::Exists("C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\"))
    {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg0 -Value "-dF:\DATA\master.mdf"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg1 -Value "-eF:\LOG\ERRORLOG"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg2 -Value "-lF:\LOG\mastlog.ldf"
    }
    elseif ([System.IO.Directory]::Exists("C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\DATA\")) 
    {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg0 -Value "-dF:\DATA\master.mdf"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg1 -Value "-eF:\LOG\ERRORLOG"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQLServer\Parameters" -Name SQLArg2 -Value "-lF:\LOG\mastlog.ldf"
    }else 
    {
            throw  "No system database folder detected,exiting ...."
    }
}

#This function will copy the Source file to target path, duplicate its permission to the new file and delete the old file
function Relocate-Files([string]$SourceFilePath, [string]$TargetFilePath)
{
    Write-Verbose -Message "Moving File $SourceFilePath to $TargetFilePath"

    [System.IO.File]::Copy($SourceFilePath, $TargetFilePath, $true)
    
    Write-Verbose -Message "Duplicating file permission of $SourceFilePath to $TargetFilePath"

    DuplicateFilePermission -SourceFilePath  $SourceFilePath  -TargetFilePath $TargetFilePath
    
    Write-Verbose -Message "Deleting $SourceFilePath"

    [System.IO.File]::Delete($SourceFilePath)
}

#Duplicate the Access properties of a source file to a target file
function DuplicateFilePermission ([string]$SourceFilePath, [string]$TargetFilePath)
{
    $SourceFile = [System.IO.FileInfo]$SourceFilePath
    $TargetFile = [System.IO.FileInfo]$TargetFilePath
    $SourceFileAccess = $SourceFile.GetAccessControl()
    $SourceFileAccess.SetAccessRuleProtection($true,$true)
    $TargetFile.SetAccessControl($SourceFileAccess)
}


#Move system databases to new File/Log Location
function Move-SystemDatabaseFile([string]$FilePath, [string]$LogPath)
{
    
    if  ([System.IO.Directory]::Exists("C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\DATA\"))
    {
        $SourceDataFilePath = "C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\DATA\"
        $SourceLogFilePath = "C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\LOG\"
    }
    elseif ([System.IO.Directory]::Exists("C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\"))
    {
        $SourceDataFilePath = "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\"
        $SourceLogFilePath = "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\LOG\"
    }
    elseif ([System.IO.Directory]::Exists("C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\DATA\")) 
    {
        $SourceDataFilePath = "C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\DATA\"
        $SourceLogFilePath = "C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\LOG\"
    }else 
    {
            throw  "No system database folder detected,exiting ...."
    }
    
    #Relocate msdb databases files    
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"msdbdata.mdf") -TargetFilePath ($FilePath+"\msdbdata.mdf")
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"msdblog.ldf") -TargetFilePath ($LogPath + "\msdblog.ldf")

    #Relocate modle databases files    
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"model.mdf") -TargetFilePath ($FilePath + "\model.mdf")
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"modellog.ldf") -TargetFilePath ($LogPath + "\modellog.ldf")

    #Relocate temp databases files    
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"tempdb.mdf") -TargetFilePath ($FilePath + "\tempdb.mdf")
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"templog.ldf") -TargetFilePath ($LogPath + "\templog.ldf")

    #Relocate master database files
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"master.mdf") -TargetFilePath ($FilePath + "\master.mdf")
    Relocate-Files -SourceFilePath ($SourceDataFilePath+"mastlog.ldf") -TargetFilePath ($LogPath + "\mastlog.ldf")
    Relocate-Files -SourceFilePath ($SourceLogFilePath + "ERRORLOG") -TargetFilePath ($LogPath + "\ERRORLOG")

}



Export-ModuleMember -Function *-TargetResource