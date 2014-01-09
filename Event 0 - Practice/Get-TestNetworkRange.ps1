#TO DO:
# Function Get-ValidIPAddressinRange -- returns all possible IP address in the Range specified
# Leverage Split-Job Function to speed-up performance

#requires -version 2.0
<#
################################################################################
## Run commands in multiple concurrent pipelines
##   by Arnoud Jansveld - www.jansveld.net/powershell
##
## Basic "drop in" usage examples:
##   - Functions that accept pipelined input:
##       Without Split-Job:
##          Get-Content hosts.txt | MyFunction | Export-Csv results.csv
##       With Split-Job:
##          Get-Content hosts.txt | Split-Job {MyFunction} | Export-Csv results.csv
##   - Functions that do not accept pipelined input (use foreach):
##       Without Split-Job:
##          Get-Content hosts.txt |% { .\MyScript.ps1 -ComputerName $_ } | Export-Csv results.csv
##       With Split-Job:
##          Get-Content hosts.txt | Split-Job {%{ .\MyScript.ps1 -ComputerName $_ }} | Export-Csv results.csv
##
## Example with an imported function:
##       function Test-WebServer ($ComputerName) {
##           $WebRequest = [System.Net.WebRequest]::Create("http://$ComputerName")
##           $WebRequest.GetResponse()
##       }
##       Get-Content hosts.txt | Split-Job {%{Test-WebServer $_ }} -Function Test-WebServer | Export-Csv results.csv
##
## Example with importing a module
##       Get-Content Clusters.txt | Split-Job { % { Get-Cluster -Name $_ } } -InitializeScript { Import-Module FailoverClusters }
##	
##
## Version History
## 1.2    Changes by Stephen Mills - stephenmills at hotmail dot com
##        Only works with PowerShell V2
##        Modified error output to use ErrorRecord parameter of Write-Error - catches Category Info then.
##        Works correctly in powershell_ise.  Previous version would let pipelines continue if ESC was pressed.  If Escape pressed, then it will do an async cancel of the pipelines and exit.
##        Add seconds remaining to progress bar
##        Parameters Added and related functionality:
##           InitializeScript - allows to have custom scripts to initilize ( Import-Module ...), parameter might be renamed Begin in the future.
##           MaxDuration - Cancel all pending and in process items in queue if the number of seconds is reached before all input is done.
##           ProgressInfo - Allows you to add additional text to progress bar
##           NoProgress - Hide Progress Bar
##           DisplayInterval - frequency to update Progress bar in milliseconds
##           InputObject - not yet used, planned to be used in future to support start processing the queue before pipeline isn't finished yet
##        Added example for importing a module.
## 1.0    First version posted on poshcode.org
##        Additional runspace error checking and cleanup
## 0.93   Improve error handling: errors originating in the Scriptblock now
##        have more meaningful output
##        Show additional info in the progress bar (thanks Stephen Mills)
##        Add SnapIn parameter: imports (registered) PowerShell snapins
##        Add Function parameter: imports functions
##        Add SplitJobRunSpace variable; allows scripts to test if they are
##        running in a runspace
## 0.92   Add UseProfile switch: imports the PS profile
##        Add Variable parameter: imports variables
##        Add Alias parameter: imports aliases
##        Restart pipeline if it stops due to an error
##        Set the current path in each runspace to that of the calling process
## 0.91   Revert to v 0.8 input syntax for the script block
##        Add error handling for empty input queue
## 0.9    Add logic to distinguish between scriptblocks and cmdlets or scripts:
##        if a ScriptBlock is specified, a foreach {} wrapper is added
## 0.8    Adds a progress bar
## 0.7    Stop adding runspaces if the queue is already empty
## 0.6    First version. Inspired by Gaurhoth's New-TaskPool script
################################################################################
#>

function Split-Job
{
	param (
		[Parameter(Position=0, Mandatory=$true)]$Scriptblock,
		[Parameter()][int]$MaxPipelines=10,
		[Parameter()][switch]$UseProfile,
		[Parameter()][string[]]$Variable,
		[Parameter()][string[]]$Function = @(),
		[Parameter()][string[]]$Alias = @(),
		[Parameter()][string[]]$SnapIn,
		[Parameter()][float]$MaxDuration = $( [Int]::MaxValue ),
		[Parameter()][string]$ProgressInfo ='',
		[Parameter()][int]$ProgressID = 0,
		[Parameter()][switch]$NoProgress,
		[Parameter()][int]$DisplayInterval = 300,
		[Parameter()][scriptblock]$InitializeScript,
		[Parameter(ValueFromPipeline=$true)][object[]]$InputObject
	)

	begin
	{
		$StartTime = Get-Date
		#$DisplayTime = $StartTime.AddMilliseconds( - $DisplayInterval )
		$ExitForced = $false


		 function Init ($InputQueue){
			# Create the shared thread-safe queue and fill it with the input objects
			$Queue = [Collections.Queue]::Synchronized([Collections.Queue]@($InputQueue))
			$QueueLength = $Queue.Count
			# Do not create more runspaces than input objects
			if ($MaxPipelines -gt $QueueLength) {$MaxPipelines = $QueueLength}
			# Create the script to be run by each runspace
			$Script  = "Set-Location '$PWD'; "
			$Script += {
				$SplitJobQueue = $($Input)
				& {
					trap {continue}
					while ($SplitJobQueue.Count) {$SplitJobQueue.Dequeue()}
				} }.ToString() + '|' + $Scriptblock

			# Create an array to keep track of the set of pipelines
			$Pipelines = New-Object System.Collections.ArrayList

			# Collect the functions and aliases to import
			$ImportItems = ($Function -replace '^','Function:') +
				($Alias -replace '^','Alias:') |
				Get-Item | select PSPath, Definition
			$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		}

		function Add-Pipeline {
			# This creates a new runspace and starts an asynchronous pipeline with our script.
			# It will automatically start processing objects from the shared queue.
			$Runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host)
			$Runspace.Open()
			if (!$?) { throw "Could not open runspace!" }
			$Runspace.SessionStateProxy.SetVariable('SplitJobRunSpace', $True)

			function CreatePipeline
			{
				param ($Data, $Scriptblock)
				$Pipeline = $Runspace.CreatePipeline($Scriptblock)
				if ($Data)
				{
					$Null = $Pipeline.Input.Write($Data, $True)
					$Pipeline.Input.Close()
				}
				$Null = $Pipeline.Invoke()
				$Pipeline.Dispose()
			}

			# Optionally import profile, variables, functions and aliases from the main runspace
			
			if ($UseProfile)
			{
				CreatePipeline -Script "`$PROFILE = '$PROFILE'; . `$PROFILE"
			}

			if ($Variable)
			{
				foreach ($var in (Get-Variable $Variable))
				{
					trap {continue}
					$Runspace.SessionStateProxy.SetVariable($var.Name, $var.Value)
				}
			}
			if ($ImportItems)
			{
				CreatePipeline $ImportItems {
					foreach ($item in $Input) {New-Item -Path $item.PSPath -Value $item.Definition}
				}
			}
			if ($SnapIn)
			{
				CreatePipeline (Get-PSSnapin $Snapin -Registered) {$Input | Add-PSSnapin}
			}
			
			#Custom Initialization Script for startup of Pipeline - needs to be after other other items added.
			if ($InitializeScript -ne $null)
			{
				CreatePipeline -Scriptblock $InitializeScript
			}

			$Pipeline = $Runspace.CreatePipeline($Script)
			$Null = $Pipeline.Input.Write($Queue)
			$Pipeline.Input.Close()
			$Pipeline.InvokeAsync()
			$Null = $Pipelines.Add($Pipeline)
		}

		function Remove-Pipeline ($Pipeline)
		{
			# Remove a pipeline and runspace when it is done
			$Pipeline.RunSpace.CloseAsync()
			#Removed Dispose so that Split-Job can be quickly aborted even if currently running something waiting for a timeout.
			#Added call to [System.GC]::Collect() at end of script to free up what memory it can.
			#$Pipeline.Dispose()
			$Pipelines.Remove($Pipeline)
		}
	}

	end
	{
		


		# Main
		# Initialize the queue from the pipeline
		. Init $Input
		# Start the pipelines
		try
		{
			while ($Pipelines.Count -lt $MaxPipelines -and $Queue.Count) {Add-Pipeline}

			# Loop through the pipelines and pass their output to the pipeline until they are finished
			while ($Pipelines.Count)
			{
				# Only update the progress bar once per $DisplayInterval
				if (-not $NoProgress -and $Stopwatch.ElapsedMilliseconds -ge $DisplayInterval)
				{
					$Completed = $QueueLength - $Queue.Count - $Pipelines.count
					$Stopwatch.Reset()
					$Stopwatch.Start()
					#$LastUpdate = $stopwatch.ElapsedMilliseconds
					$PercentComplete = (100 - [Int]($Queue.Count)/$QueueLength*100)
					$Duration = (Get-Date) - $StartTime
					$DurationString = [timespan]::FromSeconds( [Math]::Floor($Duration.TotalSeconds)).ToString()
					$ItemsPerSecond = $Completed / $Duration.TotalSeconds
					$SecondsRemaining = [math]::Round(($QueueLength - $Completed)/ ( .{ if ($ItemsPerSecond -eq 0 ) { 0.001 } else { $ItemsPerSecond}}))
					
					Write-Progress -Activity "** Split-Job **  *Press Esc to exit*  Next item: $(trap {continue}; if ($Queue.Count) {$Queue.Peek()})" `
						-status "Queues: $($Pipelines.Count) QueueLength: $($QueueLength) StartTime: $($StartTime)  $($ProgressInfo)" `
						-currentOperation  "$( . { if ($ExitForced) { 'Aborting Job!   ' }})Completed: $($Completed) Pending: $($QueueLength- ($QueueLength-($Queue.Count + $Pipelines.Count))) RunTime: $($DurationString) ItemsPerSecond: $([math]::round($ItemsPerSecond, 3))"`
						-PercentComplete $PercentComplete `
						-Id $ProgressID `
						-SecondsRemaining $SecondsRemaining
				}	
				foreach ($Pipeline in @($Pipelines))
				{
					if ( -not $Pipeline.Output.EndOfPipeline -or -not $Pipeline.Error.EndOfPipeline)
					{
						$Pipeline.Output.NonBlockingRead()
						$Pipeline.Error.NonBlockingRead() | % { Write-Error -ErrorRecord $_ }

					} else
					{
						# Pipeline has stopped; if there was an error show info and restart it			
						if ($Pipeline.PipelineStateInfo.State -eq 'Failed')
						{
							Write-Error $Pipeline.PipelineStateInfo.Reason
							
							# Restart the runspace
							if ($Queue.Count -lt $QueueLength) {Add-Pipeline}
						}
						Remove-Pipeline $Pipeline
					}
					if ( ((Get-Date) - $StartTime).TotalSeconds -ge $MaxDuration -and -not $ExitForced)
					{
						Write-Warning "Aborting job! The MaxDuration of $MaxDuration seconds has been reached. Inputs that have not been processed will be skipped."
						$ExitForced=$true
					}
					
					if ($ExitForced) { $Pipeline.StopAsync(); Remove-Pipeline $Pipeline }
				}
				while ($Host.UI.RawUI.KeyAvailable)
				{
					if ($Host.ui.RawUI.ReadKey('NoEcho,IncludeKeyDown,IncludeKeyUp').VirtualKeyCode -eq 27 -and !$ExitForced)
					{
						$Queue.Clear();
						Write-Warning 'Aborting job! Escape pressed! Inputs that have not been processed will be skipped.'
						$ExitForced = $true;
						#foreach ($Pipeline in @($Pipelines))
						#{
						#	$Pipeline.StopAsync()
						#}
					}		
				}
				if ($Pipelines.Count) {Start-Sleep -Milliseconds 50}
			}

			#Clear the Progress bar so other apps don't have to keep seeing it.
			Write-Progress -Completed -Activity "`0" -Status "`0"

			# Since reference to Dispose was removed.  I added this to try to help with releasing resources as possible.
			# This might be a bad idea, but I'm leaving it in for now. (Stephen Mills)
			[GC]::Collect()
		}
		finally
		{
			foreach ($Pipeline in @($Pipelines))
			{
				if ( -not $Pipeline.Output.EndOfPipeline -or -not $Pipeline.Error.EndOfPipeline)
				{
					Write-Warning 'Pipeline still runinng.  Stopping Async.'
					$Pipeline.StopAsync()
					Remove-Pipeline $Pipeline
				}
			}
		}
	}
}

function Get-ValidIPAddressinRange
{
<#
.Synopsis
   Takes the IP Address and the Mask value as input and returns all possible IP
.DESCRIPTION
   The Function takes the IPAddress and the Subnet mask value to generate list of all possible IP addresses in the Network.
   
.EXAMPLE
    Specify the IPaddress in the CIDR notation
    PS C:\> Get-IPAddressinNetwork -IP 10.10.10.0/24
.EXAMPLE
   Specify the IPaddress and mask separately (Non-CIDR notation)
    PS C:\> Get-IPAddressinNetwork -IP 10.10.10.0 -Mask 24
.EXAMPLE
   Specify the IPaddress and mask separately (Non-CIDR notation)
    PS C:\> Get-IPAddressinNetwork -IP 10.10.10.0 -Mask 255.255.255.0
.INPUTS
   System.String
.OUTPUTS
   [System.Net.IPAddress[]]
.NOTES
   General notes
.LINK
    http://www.indented.co.uk/index.php/2010/01/23/powershell-subnet-math/

#>
    [CmdletBinding(DefaultParameterSetName='CIDR', 
                  SupportsShouldProcess=$true, 
                  ConfirmImpact='low')]
    [OutputType([ipaddress[]])]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true, 
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true, 
                   ValueFromRemainingArguments=$false 
                    )]
        [ValidateScript({
                        if ($_.contains("/"))
                            { # if the specified IP format is -- 10.10.10.0/24
                                $temp = $_.split('/')   
                                If (([ValidateRange(0,32)][int]$subnetmask = $temp[1]) -and ([bool]($temp[0] -as [ipaddress])))
                                {
                                    Return $true
                                }
                            }                           
                        else
                        {# if the specified IP format is -- 10.10.10.0 (along with this argument to Mask is also provided)
                            if ( [bool]($_ -as [ipaddress]))
                            {
                                return $true
                            }
                            else
                            {
                                throw "IP validation failed"
                            }
                        }
                        })]
        [Alias("IPAddress","NetworkRange")] 
        [string]$IP,

        # Param2 help description
        [Parameter(ParameterSetName='Non-CIDR')]
        [ValidateScript({
                        if ($_.contains("."))
                        { #the mask is in the dotted decimal 255.255.255.0 format
                            if (! [bool]($_ -as [ipaddress]))
                            {
                                throw "Subnet Mask Validation Failed"
                            }
                            else
                            {
                                return $true 
                            }
                        }
                        else
                        { #the mask is an integer value so must fall inside range [0,32]
                           # use the validate range attribute to verify it falls under the range
                            if ([ValidateRange(0,32)][int]$subnetmask = $_ )
                            {
                                return $true
                            }
                            else
                            {
                                throw "Invalid Mask Value"
                            }
                        }
                        
                         })]
        [string]$mask
    )

    Begin
    {
        Write-Verbose "Function Starting"
        #region Function Definitions
        
        Function ConvertTo-DecimalIP {
          <#
            .Synopsis
              Converts a Decimal IP address into a 32-bit unsigned integer.
            .Description
              ConvertTo-DecimalIP takes a decimal IP, uses a shift-like operation on each octet and returns a single UInt32 value.
            .Parameter IPAddress
              An IP Address to convert.
          #>
   
          [CmdLetBinding()]
          [OutputType([UInt32])]
          Param(
            [Parameter(Mandatory = $True, Position = 0, ValueFromPipeline = $True)]
            [Net.IPAddress]$IPAddress
          )
 
          Process 
          {
            $i = 3; $DecimalIP = 0;
            $IPAddress.GetAddressBytes() | ForEach-Object { $DecimalIP += $_ * [Math]::Pow(256, $i); $i-- }
 
            Write-Output $([UInt32]$DecimalIP)
          }
        }

        Function ConvertTo-DottedDecimalIP {
          <#
            .Synopsis
              Returns a dotted decimal IP address from either an unsigned 32-bit integer or a dotted binary string.
            .Description
              ConvertTo-DottedDecimalIP uses a regular expression match on the input string to convert to an IP address.
            .Parameter IPAddress
              A string representation of an IP address from either UInt32 or dotted binary.
          #>
 
          [CmdLetBinding()]
          [OutputType([ipaddress])]
          Param(
            [Parameter(Mandatory = $True, Position = 0, ValueFromPipeline = $True)]
            [String]$IPAddress
          )
   
          Process {
            Switch -RegEx ($IPAddress) 
            {
              "([01]{8}\.){3}[01]{8}" 
              {
                Return [String]::Join('.', $( $IPAddress.Split('.') | ForEach-Object { [Convert]::ToUInt32($_, 2) } ))
              }

              "\d" 
              {
                $IPAddress = [UInt32]$IPAddress
                $DottedIP = $( For ($i = 3; $i -gt -1; $i--) {
                  $Remainder = $IPAddress % [Math]::Pow(256, $i)
                  ($IPAddress - $Remainder) / [Math]::Pow(256, $i)
                  $IPAddress = $Remainder
                 } )
        
                Write-Output $([ipaddress]([String]::Join('.', $DottedIP)))
              }

              default 
              {
                Write-Error "Cannot convert this format"
              }
            }
          }
    }
         #endregion Function Definitions
    }

    Process
    {
        Switch($PSCmdlet.ParameterSetName)
        {
            "CIDR"
            {
                Write-Verbose "Inside CIDR Parameter Set"
                $temp = $ip.Split("/")
                $ip = $temp[0]
                 #The validation attribute on the parameter takes care if this is empty
                $mask = ConvertTo-DottedDecimalIP ([Convert]::ToUInt32($(("1" * $temp[1]).PadRight(32, "0")), 2))                            
            }

            "Non-CIDR"
            {
                Write-Verbose "Inside Non-CIDR Parameter Set"
                If (!$Mask.Contains("."))
                  {
                    $mask = ConvertTo-DottedDecimalIP ([Convert]::ToUInt32($(("1" * $mask).PadRight(32, "0")), 2))
                  }

            }
        }
        #now we have appropraite dotted decimal ip's in the $ip and $mask
        $DecimalIP = ConvertTo-DecimalIP -IPAddress $ip
        $DecimalMask = ConvertTo-DecimalIP $Mask

        $Network = $DecimalIP -BAnd $DecimalMask
        $Broadcast = $DecimalIP -BOr ((-BNot $DecimalMask) -BAnd [UInt32]::MaxValue)

        For ($i = $($Network + 1); $i -lt $Broadcast; $i++) {
            ConvertTo-DottedDecimalIP $i
          }
                       
            
    }
    End
    {
        Write-Verbose "Function Ending"
    }
}



   
function Get-OSInfo
{
	<#
		.SYNOPSIS
			A brief description of the function.

		.DESCRIPTION
			A detailed description of the function.

		.PARAMETER  ParameterA
			The description of the ParameterA parameter.

		.PARAMETER  ParameterB
			The description of the ParameterB parameter.

		.EXAMPLE
			PS C:\> Get-Something -ParameterA 'One value' -ParameterB 32

		.EXAMPLE
			PS C:\> Get-Something 'One value' 32

		.INPUTS
			System.String,System.Int32

		.OUTPUTS
			System.String

		.NOTES
			Additional information about the function go here.

		.LINK
			about_functions_advanced

		.LINK
			about_comment_based_help

	#>
	[CmdletBinding()]
	[OutputType([PSObject])]
	param(
		[Parameter(Position=0, Mandatory=$true,
                    ValueFromPipeline=$true,
                    ValueFromPipelineByPropertyName=$true)]
		[ValidateNotNullOrEmpty()]
		[System.net.IPAddress]
		[Alias("IP")]
		$IPAddress
		
	)
	Begin
	{
		Write-Verbose -Message "Get-OSInfo : Starting the Function"
		Write-Verbose -Message "Get-OSInfo : Loading Function Resolve-IPAddress definition"
		Function Resolve-IPAddress
	    {
	      [CmdLetBinding()]
	          [OutputType([bool])]
	          Param(
	            [Parameter(Mandatory = $True, Position = 0, ValueFromPipeline = $True)]
	            [ipaddress]$IPAddress
	          )
	        #try to resolve the IPAddress to a host name...return true if it resolves otherwise false
	        try 
	        {
				# Add a note property to the IPAddress object if the machine name resolves..
                $hostname = ([System.Net.Dns]::GetHostEntry("$IPAddress")).HostName
	            Add-Member -MemberType NoteProperty -Name ComputerName -Value $hostname  -InputObject $IPAddress -Force
	 			Write-Output $true 
	        }
	        catch
	        {
	            Write-Warning "$IPAddress not resolving to a hostname"
	            Write-Output $false
	        }

	    }
	
	}
	Process
	{
		Write-Verbose -Message "Get-OSInfo : Working with IP Address - $IPAddress"
		
		if (Resolve-IPAddress -IPAddress $IPAddress)
		{
			Write-Verbose -Message "Get-OSInfo : $IPAddress is resolving to a hostname $IPAddress.ComputerName"
			Write-Verbose -Message "Get-OSInfo : Testing if the $IPAddress.Computername is online"
			if (Test-Connection -ComputerName $IPAddress.Computername -Count 2 -Quiet )
			{
				#IPAddress resolves to a hostname and Machine is online
				Write-Verbose -Message "Get-OSInfo : $IPAddress.Computername is online"
				try
				{
					Write-Verbose -Message "Get-OSInfo : Querying the machine name - $IPAddress.Computername"
					$OSInfo = Get-WmiObject -Class Win32_OperatingSystem -Namespace root\cimv2 -ComputerName $IPAddress.Computername -ErrorAction Stop -ErrorVariable OSinfoError
					
					#Using the Ordered Hash tables to get the Properties on Object back in  Order 
					$hash = [ordered]@{"IPAddress"=$IPaddress.IPAddressToString ;"ComputerName"=$IPAddress.Computername;"OS"=$OSInfo.Caption;"ServicePack"=$OSInfo.CSDversion;Online=$true}
                    
                    Write-Output -InputObject $([PSCustomObject]$hash)
					
				}
				catch
				{
					Write-Error -Exception $OSInfo.Exception
					$hash = [Ordered]@{"IPAddress"=$IPaddress.IPAddressToString ;"ComputerName"= $IPAddress.Computername ;"OS"=$Null;"ServicePack"=$Null;Online=$true}
                    
                        
                    Write-Output -InputObject $([PSCustomObject]$hash)
				}
			
			}
			else
			{
				#IPAddress resolves to a hostname and Machine is offline
				Write-Verbose -Message "Get-OSInfo : $IpAddress.Computername is Offline"
				$hash = [Ordered]@{"IPAddress"=$IPaddress.IPAddressToString ;"ComputerName"=$IPAddress.Computername;"OS"=$Null;"ServicePack"=$Null;Online=$False}
                
				Write-Output -InputObject $([PSCustomObject]$hash)
			}
			
		}
		else
		{
			Write-Verbose -Message "Get-OSInfo : $IPAddress is NOT resolving to a hostname"
			$hash = [Ordered]@{"IPAddress"=$IPaddress.IPAddressToString ;"ComputerName"=$Null;"OS"=$Null;"ServicePack"=$Null;Online=$False}
                
			Write-Output -InputObject $([PSCustomObject]$hash)
		
		}
	}
	End
	{
		Write-Verbose -Message "Get-OSInfo : Ending the Function"
	}
	
}