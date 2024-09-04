#!/bin/bash

# Function to display help message
show_help() {
    echo "Usage: $(basename "$0") [options]"
    echo
    echo "Options:"
    echo "  -h, --help          Show this help message and exit"
    echo "  -f, --file          Specify a .ova file to process"
    echo "  -d, --directory     Specify a directory of .ova files to process"
    echo "  -v, --verbose       Enable verbose mode"
    echo
}

import_ova_file() {
        _import_ova_file_path=$1
        _import_ova_file_dir=$(dirname "$_import_ova_file_path")

        # Check that the file path exists
        if [ ! -f "$_import_ova_file_path" ]; then
                echo "Could not find file: $_import_ova_file_path"
                return 1
        fi

        # Check file extension is .ova
        if [ ! "${_import_ova_file_path##*.}" = "ova" ]; then
                echo "File is not an OVA file: $_import_ova_file_path"
                return 1
        fi

        # Extract filename without extension
        _import_ova_file_filename_no_extension="${_import_ova_file_path##*/}"
        _import_ova_file_filename_no_extension="${_import_ova_file_filename_no_extension%.*}"
	
	# Extract .ova file
	cd "$_import_ova_file_dir"
	tar -xvf "./$_import_ova_file_path"
	
	# Unzip the vmdk file as needed
	_import_ova_file_vmdk_file=$(ls | grep "$_import_ova_file_no_extension.*disk.*\.vmdk$")

	if [ ! "${_import_ova_file_vmdk_file##*.}" = "gz" ]; then
		gzip -d "$_import_ova_file_vmdk_file"	
	fi


        # Next:
        # Search to see if a filename_no_ext.ovf or filename_no_ext.ova.ovf exists
        # If not extract .ova with tar -xvf
        # Then extract vmdk file with gunzip
        # Then import with qm
}

# Parse command-line args
while [[ "$1" != "" ]]; do
        case $1 in
                -h | --help )
                        show_help
                        exit 0
                        ;;

                -f | --file )
                        shift
                        import_ova_file $1
                        ;;

                -d | --directory )
                        shift
                        import_directory $1
                        ;;

                * )
                        echo "Unknown option: $1"
                        show_help
                        exit 1
                        ;;
        esac
        shift
done
