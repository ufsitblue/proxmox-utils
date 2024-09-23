#!/bin/bash

# Globals
START_VMID=0
REQUIRED_COMMANDS="tar qm lvremove gunzip qemu-img"

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

check_commands() {
  all_exist=0  # Assume all commands exist initially

  for cmd in "$@"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "Command '$cmd' exists."
    else
      echo "Command '$cmd' does not exist."
      all_exist=1  # Set to 1 if any command does not exist
    fi
  done

  return $all_exist  # Return 0 if all exist, 1 if any are missing
}

import_ova_file() {
        _import_ova_file_path=$1
        _import_ova_file_vmid=$2
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
	

        # Import OVF
        _file_extensions=".ovf .ova.ovf"
        for _file_extension in $_file_extensions; do
                if [ -f "${_import_ova_file_filename_no_extension}${_file_extension}" ]; then
                        qm importovf "$_import_ova_file_vmid" "${_import_ova_file_filename_no_extension}${_file_extension}" local-lvm
                        break
                else
                        echo "Extracted OVA is missing the OVF: ${_import_ova_file_filename_no_extension}${_file_extension}"
                fi
        done

        # Delete the imported disk
        # This is because the imported VMDK doesn't work normally
        # This also assumes there is only one disk per VM
        qm set "$_import_ova_file_vmid" -delete scsi0
        qm set "$_import_ova_file_vmid" -delete unused0
        lvremove "/dev/pve/vm-$_import_ova_file_vmid-disk-0"

        # Unzip the VMDK file if needed
        _import_ova_file_vmdk_file=""
        for _file in "$_import_ova_file_filename_no_extension"*disk*.vmdk*; do
                _import_ova_file_vmdk_file="$_file"
                
                # Get the file extension using parameter expansion (faster than awk)
                _file_extension="${_import_ova_file_vmdk_file##*.}"
                
                if [ "$_file_extension" = "gz" ]; then
                        gzip -d "$_import_ova_file_vmdk_file"
                        break  # Exit after handling the first gzipped file
                fi
        done

        if [ -z "$_import_ova_file_vmdk_file" ]; then
                echo "Failed to find a VMDK file from the extracted OVA: $_import_ova_file_path"
                exit_fail
        fi

        # Convert the VMDK to a compressed Qcow2 image
        _import_ova_file_qcow_image="$_import_ova_file_filename_no_extension.qcow2"
        qemu-img convert -f vmdk -O qcow2 -c "$_import_ova_file_filename_no_extension.ova-disk1.vmdk" "$_import_ova_file_qcow_image"

        # Import converted image
        qm importdisk "$_import_ova_file_vmid" "$_import_ova_file_qcow_image" local-lvm
        qm set "$_import_ova_file_vmid" --scsi0 "local-lvm:vm-$_import_ova_file_vmid-disk-0"

        echo "Succesfully imported: $_import_ova_file_filename_no_extension.ova"
}       

validate_vmid() {
    _validate_vmid_vmid="$1"
    _validate_vmid_range="$2"

    # Check if the starting VMID is within the valid Proxmox range
    if ! [ "$_validate_vmid_vmid" -ge 100 ] 2>/dev/null || ! [ "$_validate_vmid_vmid" -le 999999999 ]; then
        echo "Error: Starting VMID must be a number between 100 and 999999999."
        return 1
    fi

    # Validate the range argument (it should be a positive number)
    if ! [ "$_validate_vmid_range" -ge 1 ] 2>/dev/null; then
        echo "Error: Range must be a positive number."
        return 1
    fi

    # Loop through the VMID range and check for availability
    _validate_vmid_current_vmid="$_validate_vmid_vmid"
    _validate_vmid_end_vmid=$((_validate_vmid_vmid + _validate_vmid_range - 1))

    while [ "$_validate_vmid_current_vmid" -le "$_validate_vmid_end_vmid" ]; do
        # Check if the VMID is already in use
        if [ -f "/etc/pve/qemu-server/${_validate_vmid_current_vmid}.conf" ]; then
            echo "Error: VMID ${_validate_vmid_current_vmid} is already taken."
            return 1
        fi
        _validate_vmid_current_vmid=$((_validate_vmid_current_vmid + 1))
    done

    return 0
}

validate_directory_exists() {
    _validate_dir_path="$1"

    # Check if the provided path is a directory
    if [ ! -d "$_validate_dir_path" ]; then
        echo "Error: Directory '$_validate_dir_path' does not exist."
        exit 1
    fi

    return 0
}

count_ova_files_in_directory() {
    _validate_ova_dir_path="$1"

    # Validate the directory first
    
    if ! validate_directory_exists "$_validate_ova_dir_path"; then
        exit 1  # Exit if directory does not exist
    fi

    # Recursively count the number of .ova files in the directory
    _validate_ova_count=$(find "$_validate_ova_dir_path" -type f -name "*.ova" | wc -l)

    return "$_validate_ova_count"
}

# Function to generate a random number between 100 and 1000 (factors of 10)
generate_random_vmid() {
    shuf -i 10-100 -n 1 | awk '{print $1 * 10}'
}

find_valid_vmid_range() {
    while :; do
        # Generate a random VMID
        _find_valid_vmid_range_random_vmid=$(generate_random_vmid)

        # Validate the VMID with a range of 20
        if validate_vmid "$_find_valid_vmid_range_random_vmid" 20; then
            return "$_find_valid_vmid_range_random_vmid"
        fi
    done
}

exit_success() {
        echo "Finished. Exiting..."
        exit 0
}

exit_fail() {
        echo "Error. Exiting..."
        exit 1
}

# Parse command-line args
while [[ "$1" != "" ]]; do
        # Verify that all commands are present
        if check_commands "$REQUIRED_COMMANDS" -eq 0; then
                echo "All required commands exist."
        else
                echo "Some required commands are missing."
                exit_fail
        fi

        # Find a valid VMID range for imported images
        START_VMID=$(find_valid_vmid_range)

        case $1 in
                -h | --help )
                        show_help
                        exit 0
                        ;;
                                
                -i | --start-vmid )
                        shift
                        START_VMID="$1"
                        ;;

                -f | --file )
                        shift
                        validate_vmid "$START_VMID" 1
                        import_ova_file "$1" "$START_VMID" # When importing only one VM just use the START_VMID directly
                        exit_success
                        ;;

                -d | --directory )
                        shift
                        num_ova_files=$(count_ova_files_in_directory "$1")
                        validate_vmid "$START_VMID" "$num_ova_files"
                        import_directory "$1"
                        exit_success
                        ;;

                * )
                        echo "Unknown option: $1"
                        show_help
                        exit_fail
                        ;;
        esac
        shift
done



# Tested manual process:
#-----------------------#
# tar -xvf .ova
# qm importovf 333 ova.ovf local-lvm
# qm set 333 -delete scsi0
# qm set 333 -delete unused0
# lvremove /dev/pve/vm-<VMID>-disk-<disk-number>
# gunzip *.ova-disk1.vmdk.gz
# qemu-img convert -f vmdk -O qcow2 -c ./*.ova-disk1.vmdk ./*.qcow2
# qm importdisk <VMID> ./*.qcow2 local-lvm
# qm set <VMID> --scsi0 local-lvm:vm-<VMID>-disk-0
