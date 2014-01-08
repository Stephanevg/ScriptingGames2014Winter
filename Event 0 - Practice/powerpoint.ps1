﻿#========================================================================
# Created with: SAPIEN Technologies, Inc., PowerShell Studio 2012 v3.1.21
# Created on:   1/8/2014 7:35 PM
# Created by:   Administrator
# Organization: 
# Filename:     
#========================================================================

#MSDN help articles

#Shapes: http://msdn.microsoft.com/en-us/library/office/bb265573(v=office.12).aspx

function ExportTo-PowerPoint {
		<#
	.SYNOPSIS
	Exports Charts to PowerPoint format

	.DESCRIPTION
	Export the graphs to a powerpoint presentation.
	
	.PARAMETER  <ExportPath>
	Specifies de export path (must be have either .ppt or pptx as extension).
	
	.PARAMETER  <Debug>
	This parameter is optional, and will if called, activate the deubbing mode wich can help to troubleshoot the script if needed. 

	.NOTES
	-Version 0.1
	-Author : Stéphane van Gulick
	-Creation date: 01/06/2012
	-Creation date: 01/06/2012
	-Script revision history
	##0.1 : Initilisation
	##0.2 : First version
	##0.3 : Added Image possibilities

	.EXAMPLE
	Exportto-html -Data (Get-Process) -Path "d:\temp\export.html" -title "Data export"
	
	Exports data to a HTML file located in d:\temp\export.html with a title "Data export"
	
	.EXAMPLE
	In order to call the script in debugging mode
	Exportto-html  -Image $ByteImage -Data (Get-service) "d:\temp\export.html" -title "Data Service export"
	
	Exports data to a HTML file located in d:\temp\export.html with a title "Data export". Adds also an image in the HTML output.
	#Remark: -image must be  of Byte format.
#>
	
	[cmdletbinding()]
	
		Param(
		
		[Parameter(mandatory=$true)]$ExportPath = $(throw "Path is mandatory, please provide a value."),
		[Parameter(mandatory=$true)]$GraphInfos,
		[Parameter(mandatory=$false)]$title,
		[Parameter(mandatory=$false)]$Subtitle
		
		)

	Begin {
		Add-type -AssemblyName office

		#DEfining PowerPoints main variables
			$MSTrue=[Microsoft.Office.Core.MsoTriState]::msoTrue
			$MsFalse=[Microsoft.Office.Core.MsoTriState]::msoFalse
			$slideTypeTitle = [microsoft.office.interop.powerpoint.ppSlideLayout]::ppLayoutTitle
			$SlideTypeChart = [microsoft.office.interop.powerpoint.ppSlideLayout]::ppLayoutChart
			
		#Creating the ComObject
			$Application = New-Object -ComObject powerpoint.application
			$application.visible = $MSTrue
	}
	Process{
		#Creating the presentation
			$Presentation = $Application.Presentations.add() 
		#Adding the first slide
			$Titleslide = $Presentation.Slides.add(1,$slideTypeTitle)
			$Titleslide.Shapes.Title.TextFrame.TextRange.Text = $Title
			$Titleslide.BackgroundStyle = 11

		#Adding the charts
		foreach ($Graphinfo in $GraphInfos) {

			#Adding slide
			$slide = $Presentation.Slides.add($Presentation.Slides.count+1,$SlideTypeChart)

			#Defining slide type:
			#http://msdn.microsoft.com/en-us/library/microsoft.office.interop.powerpoint.ppslidelayout(v=office.14).aspx
					$slide.Layout = $SlideTypeChart
					$slide.BackgroundStyle = 11
					$slide.Shapes.Title.TextFrame.TextRange.Text = $Graphinfo.title
			#Adding picture (chart) to presentation:
				#http://msdn.microsoft.com/en-us/library/office/bb230700(v=office.12).aspx
					$Picture = $slide.Shapes.AddPicture($Graphinfo.Path,$mstrue,$msTrue,300,100,350,400)
		}
	}
end {
		$presentation.Saveas($exportPath)
	 	$presentation.Close()
	}
	
}

#$b= Get-Base64Image "E:\Users\Administrator\Pictures\Pepe-thumbs-up.jpg"

$a=@()
$obj1 = [pscustomobject]@{Path="E:\Users\Administrator\Pictures\Pepe-thumbs-up.jpg"; Title="Pepe ze Praawn !!"}
$a += $obj1 
$obj2 = [pscustomobject]@{Path="E:\Users\Administrator\Pictures\vlcsnap-2013-08-20-23h52m03s141.png"; Title="Woopy di woof!!"}
$a += $obj2