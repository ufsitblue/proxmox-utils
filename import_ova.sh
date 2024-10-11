#!/bin/sh

# Globals
START_VMID=0
REQUIRED_COMMANDS="tar qm lvremove gunzip qemu-img expr"

# Function to display help message
show_help() {
    echo "Usage: $(basename "$0") [options]"
    echo
    echo "Options:"
    echo "  -h, --help          Show this help message and exit"
    echo "  -f, --file          Specify a single .ova file to process"
    echo "  -d, --directory     Specify a directory of .ova files to process recursively"
    echo "  -i, --start-vmid    Specify starting VMID for imported OVAs."
    echo
}

# Function to check if all commands in the list exist
check_commands() {
    all_exist=0
    for cmd in $1; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Command '$cmd' does not exist."
            all_exist=1
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
    _import_ova_file_filename="${_import_ova_file_path##*/}"
    _import_ova_file_filename_no_extension="${_import_ova_file_filename%.*}"

    # Extract .ova file
    echo "Found OVA file: $_import_ova_file_filename"
    echo "Extracting OVA file..."
    cd "$_import_ova_file_dir" || echo "Could not enter directory: $_import_ova_file_dir."
    tar -xvf "$_import_ova_file_path" > /dev/null
    if [ $? -ne 0 ]; then
        exit_fail
    fi


    # Import OVF
    _file_extensions=".ovf .ova.ovf"
    _import_ova_file_found_ovf=0
    for _file_extension in $_file_extensions; do
            if [ -f "${_import_ova_file_filename_no_extension}${_file_extension}" ]; then
                    echo "Found OVF file: ${_import_ova_file_filename_no_extension}${_file_extension}"
                    echo "Importing OVF file..."
                    qm importovf "$_import_ova_file_vmid" "${_import_ova_file_filename_no_extension}${_file_extension}" local-lvm > /dev/null
                    _import_ova_file_found_ovf=1
                    break
            fi
    done

    if [ $_import_ova_file_found_ovf -ne 1 ]; then
            echo "Extracted OVA is missing the OVF: ${_import_ova_file_filename_no_extension}${_file_extension}"
            exit_fail
    fi

    # Delete the imported disk
    # This is because the imported VMDK doesn't work normally
    # This also assumes there is only one disk per VM
    echo "Deleting initial disk..."
    qm set "$_import_ova_file_vmid" -delete scsi0 > /dev/null
    qm set "$_import_ova_file_vmid" -delete unused0 > /dev/null
    lvremove "/dev/pve/vm-$_import_ova_file_vmid-disk-0" > /dev/null 2>&1

    # Unzip the VMDK file if needed
    _import_ova_file_vmdk_file=""
    for _file in "$_import_ova_file_filename_no_extension"*disk*.vmdk*; do
            _import_ova_file_vmdk_file="$_file"
            
            # Get the file extension using parameter expansion (faster than awk)
            _file_extension="${_import_ova_file_vmdk_file##*.}"
            
            if [ "$_file_extension" = "gz" ]; then
                    echo "Unzipping VMDK disk file..."
                    gzip -d "$_import_ova_file_vmdk_file"
                    break  # Exit after handling the first gzipped file
            fi
    done

    if [ -z "$_import_ova_file_vmdk_file" ]; then
            echo "Failed to find a VMDK file from the extracted OVA: $_import_ova_file_path"
            exit_fail
    fi

    # Convert the VMDK to a compressed Qcow2 image
    echo "Converting VMDK disk to Qcow2..."
    _import_ova_file_qcow_image="$_import_ova_file_filename_no_extension.qcow2"
    qemu-img convert -f vmdk -O qcow2 -c "$_import_ova_file_filename_no_extension.ova-disk1.vmdk" "$_import_ova_file_qcow_image"

    # Import converted image
    echo "Importing Qcow2 image..."
    qm importdisk "$_import_ova_file_vmid" "$_import_ova_file_qcow_image" local-lvm > /dev/null
    qm set "$_import_ova_file_vmid" --scsi0 "local-lvm:vm-$_import_ova_file_vmid-disk-0" > /dev/null

    echo "Cleaning up files..."
    cleanup_files "$_import_ova_file_dir" "$_import_ova_file_filename_no_extension"
    echo "Succesfully imported: $_import_ova_file_filename_no_extension (VMID: $_import_ova_file_vmid)"
}       

# Function to convert relative path to absolute path
get_absolute_path() {
    _relative_path=$1

    # If the path starts with "/", it is already an absolute path
    case "$_relative_path" in
        /*) 
            echo "$_relative_path"
            ;;
        *)
            # Convert the relative path to an absolute path using pwd
            echo "$(cd "$(dirname "$_relative_path")" && pwd)/$(basename "$_relative_path")"
            ;;
    esac
}

import_directory() {
    # Convert directory to an absolute path
    _import_directory_dir=$(get_absolute_path "$1")
    validate_directory_exists "$_import_directory_dir"

    find "$_import_directory_dir" -type f -name '*.ova' | while IFS= read -r _import_directory_ova_file
    do
        echo "Found OVA file: $_import_directory_ova_file"
        
        # Ensure the OVA file path is absolute as well
        _absolute_ova_file=$(get_absolute_path "$_import_directory_ova_file")
        
        # Call the import function with the absolute path
        import_ova_file "$_absolute_ova_file" "$START_VMID"
        START_VMID=$((START_VMID + 1))
    done
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
    _validate_vmid_end_vmid=$((_validate_vmid_vmid + $_validate_vmid_range - 1))

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

    echo "$_validate_ova_count"
}

# Function to generate a random number between 100 and 1000 (factors of 10)
generate_random_vmid() {
    shuf -i 10-100 -n 1 | awk '{print $1 * 10}'
}

find_valid_vmid_range() {
    _find_valid_vmid_range_size=$1

    while :; do
        # Generate a random VMID
        _find_valid_vmid_range_random_vmid=$(generate_random_vmid)

        # Validate the VMID with specified range
        if validate_vmid "$_find_valid_vmid_range_random_vmid" $_find_valid_vmid_range_size; then
           break 
        fi
    done

    echo "$_find_valid_vmid_range_random_vmid"
}

cleanup_files() {
    _cleanup_files_dir="$1"
    _cleanup_files_basename_pattern="$2"

    if ! validate_directory_exists "$_cleanup_files_dir"; then
        echo "Couldn't clean up files. Directory: $_cleanup_files_dir not found!"
        exit_fail
    fi

    find "$_cleanup_files_dir" -type f ! -name '*.ova' ! -name '*.sh' -name "*$_cleanup_files_basename_pattern*" -exec rm -f {} +
}

exit_success() {
        echo "Finished. Exiting..."
        exit 0
}

exit_fail() {
        echo "Error. Exiting..."
        exit 1
}

# MAIN LOGIC:
#------------#

# Verify that all commands are present
check_commands "$REQUIRED_COMMANDS"
if [ $? -ne 0 ]; then
    echo "Some required commands are missing."
    exit_fail
fi

# Parse command-line args
while [ "$1" != "" ]; do
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

            # Find a VMID if one was not specified
            if [ "$START_VMID" -eq 0 ]; then
                echo "Looking for an unused VMID..."
                START_VMID=$(find_valid_vmid_range 1)
                echo "Using VMID: $START_VMID"
            fi
            
            validate_vmid "$START_VMID" 1
            import_ova_file "$(get_absolute_path "$1")" "$START_VMID" # When importing only one VM just use the START_VMID directly
            exit_success
            ;;
        -d | --directory )
            shift
            num_ova_files=$(count_ova_files_in_directory "$1")

            # Find a VMID if one was not specified
            if [ "$START_VMID" -eq 0 ]; then
                echo "Looking for a range $num_ova_files unused VMIDs..."
                START_VMID=$(find_valid_vmid_range 1)
                echo "Using start VMID: $START_VMID"
            fi

            validate_vmid "$START_VMID" "$num_ova_files"
            import_directory "$1"
            exit_success
            ;;
        * )
            echo "Unknown option: $1"
            show_help
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
