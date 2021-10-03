#!/bin/bash

# 2021-09-05 J.Nider
# HP Scanner listener for "Scan to Computer" function
# loosely based on https://github.com/0x27/mrw-code/blob/master/opt/hp-scanner-monitor/monitor-scanner-for-matt.sh

# There are two flows: Computer initiated and scanner initiated. This script implements only the
# computer initiated flow.

# The computer initiated flow polls the events from the printer until it signals that a scan is requested.
# [comp] GET /WalkupScanToComp/WalkupScanToCompEvent
# [scan] 200 OK ScanRequested
# [comp] GET /WalkupScanToComp/WalkupScanToCompDestinations/<uuid>

# The scanner initiated flow posts a request to the computer directly
# [scan] POST /<uuid>
# [comp] 202
# [comp] POST / (validate scan ticket)
# [scan] 200 OK (with data attached)

# load config variables:
#   printerIP: IP address (or name) of the printer
#   output_dir: directory to put scanned files
config_dir=/etc/hp-scan-monitor
. $config_dir/config

function ParseImageInfo()
{
	local info=("$@")
	local line

	# echo "Image Info:"
	for line in ${info[*]}; do
		case $line in
		*"<pwg:JobUuid>"*)
			job_uuid=${line#*Uuid>}
			job_uuid=${job_uuid%<*}
			# echo "   Job UUID: $job_uuid"
			;;

		*"<scan:ActualWidth>"*)
			width=${line#*Width>}
			width=${width%<*}
			echo "   Width: $width"
			;;

		*"<scan:ActualHeight>"*)
			height=${line#*Height>}
			height=${height%<*}
			echo "   Height: $height"
			;;
		esac
	done
}

function ParseScannerStatus()
{
	local info=("$@")
	local line

	for line in ${info[*]}; do
		case $line in
		*"<scan:JobInfo>"*)
			state="state_jobinfo"
			;;

		*"</scan:JobInfo>"*)
			state="state_start"
			;;

		*"<pwg:JobUuid>"*)
			if [[ $state == "state_jobinfo" ]]; then
				job_uuid=${line#*Uuid>}
				job_uuid=${job_uuid%<*}
			fi
			;;
		esac
	done
}

function ReceiveScannedFile()
{
	local num=0

	# create unique output filename
	printf -v filename "scan%04i.bin" $num
	while
		[[ -e $output_dir/$filename ]]
	do
		num=$((num + 1))
		printf -v filename "scan%04i.bin" $num
	done

	# "stream" the output document as it's being scanned
	echo "Getting document $output_dir/$filename"
	job_status=$(curl -s -X GET http://$printerIP/eSCL/ScanJobs/$job_uuid/NextDocument -o $output_dir/$filename)

	img_info=($(curl -s http://$printerIP/eSCL/ScanJobs/$job_uuid/ScanImageInfo))
	ParseImageInfo ${img_info[@]}

	# make sure the scanner says it was successful
	scanner_status=($(curl -s http://$printerIP/eSCL/ScannerStatus))
	ParseScannerStatus ${scanner_status[@]}
}

function ParseRegistrations()
{
	local registrations=("$@")
	local state="state_start"
	local line
	local tmp_name
	local tmp_uuid

	for line in ${registrations[*]}; do
		case $line in
		*'<wus:WalkupScanToCompDestination>'*)
			state="state_wus"
			;;

		*'</wus:WalkupScanToCompDestination>'*)
			state="state_start"
			echo "  hostname: $tmp_name uuid: $tmp_uuid"
			if [[ $registered ]]; then
				host_uuid=$tmp_uuid
				hostname=$tmp_name
				break
			fi
			;;

		*'<dd:ResourceURI>'*)
			if [[ $state == "state_wus" ]]; then
				uri=${line#*URI>}
				uri=${uri%<*}
				tmp_uuid=${uri##*/}
			fi
			;;

		*'<dd3:Hostname>'*)
			if [[ $state == "state_wus" ]]; then
				tmp_name=${line#*Hostname>}
				tmp_name=${tmp_name%<*}
				if [[ $tmp_name == $HOSTNAME ]]; then
					registered=true
				fi
			fi
			;;
		esac
	done
}

function ParseScanEvent()
{
	local event=("$@")
	local state="state_start"
	local line

	for line in ${event[*]}; do
		case $line in
		*'<wus:WalkupScanToCompEventType>'*)
			evt_type=${line#*Type>}
			evt_type=${evt_type%<*}
			#echo "Event type: $evt_type"
			;;
		esac
	done
}

function ParseEvents()
{
	local events=("$@")
	local state="state_start"
	local line

	for line in ${events[*]}; do
		#echo $line
		case $line in
		*'<ev:Event>'*)
			if [[ $state == "state_start" ]]; then
				state="state_event"
			fi
			;;

		*"</ev:Event>"*)
			# always reset to 'start' no matter what state we're in
			state="state_start"
			;;

		*"<dd:UnqualifiedEventCategory>"*)
			if [[ $state == "state_event" ]]; then
				category=${line#*Category>}
				category=${category%<*}

				if [[ $category == "ScanEvent" ]]; then
					#echo "Got scan event"
					state="state_scan_event"
					scan_event=true
				fi
			fi
			;;

		*"<dd:ResourceURI>"*)
			if [[ $state == "state_scan_event" ]]; then
				uri=${line#*URI>}
				uri=${uri%<*}
				#echo "resource uri: $uri"
			fi
			;;

		*"<dd:ResourceType>"*)
			if [[ $state == "state_scan_event" ]]; then
				rtype=${line#*Type>}
				rtype=${rtype%<*}
				#echo "resource type: $rtype"
			fi
			;;
		esac
	done
}

function RegisterIfNeeded()
{
	# Check to see if we are already registered
	registered=false
	registrations=($(curl -s http://$printerIP/WalkupScanToComp/WalkupScanToCompDestinations))
	ParseRegistrations ${registrations[@]}

	if [[ $registered == false ]]; then
		echo $xml_register > /tmp/register.xml

		# Send a POST request containing XML which describes us
		echo "Registering computer destination"
	  	response=$(curl -s -v -X POST -d @/tmp/register.xml --header 'Content-Type: text/xml' http://$printerIP/WalkupScanToComp/WalkupScanToCompDestinations 2>&1 | grep Location)

  		# Strip off the preceding "< Location: " text to get the URI and then trim trailing whitespace
	  	url="${response:12}"
  		url="${url%"${url##*[![:space:]]}"}"
		host_uuid=${response##*/}
		host_uuid="${uuid%"${uuid##*[![:space:]]}"}"
	fi
	#echo "got uuid=$host_uuid"
}

function StartScan()
{
	local registrations=("$@")
	local state="state_start"
	local line

	# Send a request to our unique URL to get any specific details we need
	xml=$(curl -s -X GET $printerIP/WalkupScanToComp/WalkupScanToCompDestinations/$host_uuid)

	echo "Scan destination details"
	for line in ${xml[*]}; do
		case $line in
		*'<dd:ResourceURI>'*)
			uri=${line#*URI>}
			uri=${uri%<*}
			host_uuid=${uri##*/}
			echo "   URI: $uri"
			;;

		*'<dd:Name>'*)
			name=${line#*Name>}
			name=${name%<*}
			echo "   Name: $name"
			;;

		*'<dd3:Hostname>'*)
			hostname=${line#*Hostname>}
			hostname=${hostname%<*}
			echo "   Hostname: $hostname"
			;;
		esac
	done

	# Send a request to specify the scan settings and start the scan
	echo "Starting scan"
	response=$(curl -s -v -X POST -d @$config_dir/scan.xml --header 'Content-Type: text/xml' http://$printerIP/eSCL/ScanJobs 2>&1 | grep Location)
    
	# read job uuid from the response
	job_uuid=${response##*/}
 	job_uuid="${job_uuid%"${job_uuid##*[![:space:]]}"}"
	echo "Created job uuid=$job_uuid"
}


xml_register='<?xml version="1.0" encoding="UTF-8"?>
<WalkupScanToCompDestination xmlns="http://www.hp.com/schemas/imaging/con/ledm/walkupscan/2010/09/28" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.hp.com/schemas/imaging/con/ledm/walkupscan/2010/09/28 WalkupScanToComp.xsd">
	<Hostname xmlns="http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06">'$HOSTNAME'</Hostname>
	<Name xmlns="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">'$HOSTNAME'</Name>
	<LinkType>Network</LinkType>
</WalkupScanToCompDestination>'

echo Starting HP printer monitor

caps=$(curl -s -X GET http://$printerIP/Scan/ScanCaps)
wus_caps=$(curl -s http://$printerIP/WalkupScanToComp/WalkupScanToCompCaps)
# GET /eSCL/ScannerCapabilities

echo Connecting to printer at $printerIP
xml=$(curl -s -X GET http://$printerIP/WalkupScanToComp/WalkupScanToCompDestinations)

if [[ -z "$xml" ]]; then
	# We didn't get a good XML response, probably because we're not connected
	echo "No connection to printer"
	exit
fi

echo "Checking registered computers"
RegisterIfNeeded

if [[ -z "$host_uuid" ]]; then
	# We didn't get a good URL - we might have been disconnected
	echo "Connection lost before we got our unique URL"
	exit
fi

	# Get the initial set of events from the scanner
	events=$(curl -s -X GET http://$printerIP/EventMgmt/EventTable)
   if [[ -z "$events" ]]; then
      # We didn't get a good response - we might have been disconnected
      echo "Connection lost before we could check the printer has acknowledged us"
		sleep 5
		continue
	fi

# check for new events
while :
do
	unset events

  	# Send a GET request to check for new scan events
	echo "Waiting for new scan event"
	while [[ -z "$events" ]]
	do
		events=($(curl -s -X GET http://$printerIP/EventMgmt/EventTable?timeout=1200))

		# recheck registration periodically in case the scanner is rebooted
		RegisterIfNeeded
	done

	scan_event=false
	ParseEvents ${events[@]}

	# ignore non-scan events
	if [[ $scan_event == false ]]; then
		continue
	fi

  	echo "Printer has a new event for us"
	# Check more details about the event
	xml=$(curl -s -X GET $printerIP/WalkupScanToComp/WalkupScanToCompEvent)
	if [[ -z "$xml" ]]; then
		# We didn't get a good response - we might have been disconnected
		echo "Connection lost before we could check the printer has acknowledged us"
		continue
	fi

	# Figure out what kind of event we got
	evt_type=""
	ParseScanEvent ${xml[@]}

	case $evt_type in 
	"ScanRequested")
		echo "Scan requested"
		StartScan
		ReceiveScannedFile
		sleep 10
		;;

	"ScanPagesComplete")
		echo "Complete!"
		continue
		;;

	"HostSelected")
		echo "Host selected"
		continue
		;;
	esac
done
