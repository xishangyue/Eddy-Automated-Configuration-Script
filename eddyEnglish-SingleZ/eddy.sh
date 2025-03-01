#!/bin/bash

# ====================================================
# Script Name: setup_printer_config.sh
# Function:
#   1. Check if ~/printer_data/config/eddypz.cfg exists, delete it if it does, then recreate it with configuration content.
#   2. Add "[include eddypz.cfg] #eddy configuration" to the first line of ~/printer_data/config/printer.cfg if it doesn't already exist.
#   3. Remove the section in ~/printer_data/config/printer.cfg where [bed_mesh] has a horizontal_move_z value of 2.
# Usage:
#   ./setup_printer_config.sh
# ====================================================

# Set target file paths
PRINTER_CFG="$HOME/printer_data/config/printer.cfg"
EDDPZ_CFG="$HOME/printer_data/config/eddypz.cfg"
FILE="$HOME/klipper/klippy/extras/ldc1612.py"

# Define content to add to printer.cfg
PRINTER_CFG_CONTENT="[include eddypz.cfg]"
PRINTER_CFG_CONTEN="[probe_eddy_current fly_eddy_probe]\nz_offset: 2.0"

# Define content to add to eddypz.cfg, handled separately
PROBE_EDDY_CURRENT=$(cat <<EOF
[probe_eddy_current fly_eddy_probe]
sensor_type: ldc1612
i2c_address: 43
i2c_mcu: SHT36
i2c_bus: i2c1e
x_offset: 0 # Remember to set x offset
y_offset: 0 # Remember to set y offset 
speed:10
lift_speed: 15.0
EOF
)

TEMPERATURE_PROBE=$(cat <<EOF
[temperature_probe fly_eddy_probe]
sensor_type: Generic 3950
sensor_pin:SHT36:gpio28
EOF
)

FORCE_MOVE=$(cat <<EOF
[force_move]
enable_force_move: true
EOF
)

GCODE_MACRO_CALIBRATE_EDDY=$(cat <<EOF
[gcode_macro CALIBRATE_EDDY]
description: Execute Eddy Current Sensor Calibration and Subsequent Leveling Process
gcode:
    # ========== Start Calibrating Eddy Current Sensor ==========
    M117 Starting Eddy Current Sensor Calibration...

    # Safety Check: Verify if the printer is in pause state
    {% if printer.pause_resume.is_paused|lower == 'true' %}
        {action_raise_error("Please resume printing before calibration")}
    {% endif %}

    # Home X/Y axes 
    G28 X Y 

    # Move print head to center of heat bed (suitable for most CoreXY models)
    G0 X{printer.toolhead.axis_maximum.x / 2} Y{printer.toolhead.axis_maximum.y / 2} F6000 
    
    SET_KINEMATIC_POSITION X={printer.toolhead.axis_maximum.x / 2} Y={printer.toolhead.axis_maximum.y / 2} Z={printer.toolhead.axis_maximum.z-10}

    # Execute Calibration Process 
    LDC_CALIBRATE_DRIVE_CURRENT CHIP=fly_eddy_probe 

    # Attempt to output DRIVE_CURRENT_FEEDBACK value
    M117 Eddy Current Calibration Complete, Feedback Value: {DRIVE_CURRENT_FEEDBACK}

    # Check if Feedback Value is within Normal Range
    {% if DRIVE_CURRENT_FEEDBACK is defined %}
        {% if DRIVE_CURRENT_FEEDBACK < 10 or DRIVE_CURRENT_FEEDBACK > 20 %}
            M117 Warning: Eddy Current Feedback Value Abnormal ({DRIVE_CURRENT_FEEDBACK}). Please check connections.
        {% else %}
            M117 Eddy Current Feedback Value Normal ({DRIVE_CURRENT_FEEDBACK}).
        {% endif %}
    {% else %}
        M117 Error: Unable to retrieve DRIVE_CURRENT_FEEDBACK value.
    {% endif %}

    # Prompt user to perform manual Z Offset Calibration
    M117 Please perform manual Z Offset Calibration.

    # Execute Eddy Effective Distance Calibration
    PROBE_EDDY_CURRENT_CALIBRATE CHIP=fly_eddy_probe 

    # Indicate Calibration Completion
    M117 All Calibration Processes Completed!
EOF
)

GCODE_MACRO_TEMP_COMPENSATION=$(cat <<EOF
[gcode_macro TEMP_COMPENSATION]
description: Temperature Compensation Calibration Process
gcode:
  {% set bed_temp = params.BED_TEMP|default(90)|int %}
  {% set nozzle_temp = params.NOZZLE_TEMP|default(250)|int %}
  {% set min_temp = params.MIN_TEMP|default(40)|int %}
  {% set max_temp = params.MAX_TEMP|default(70)|int %}
  {% set temperature_range_value = params.TEMPERATURE_RANGE_VALUE|default(3)|int %}
  {% set desired_temperature = params.DESIRED_TEMPERATURE|default(80)|int %}
  {% set Temperature_Timeout_Duration = params.TEMPERATURE_TIMEOUT_DURATION|default(6500000000)|int %}
    # Safety check: Ensure all axes are unlocked
    {% if printer.pause_resume.is_paused %}
        { action_raise_error("Error: Printer is paused. Please resume first.") }
    {% endif %}
    # Step 1: Home all axes
    STATUS_MESSAGE="Homing all axes..."
    G28
    STATUS_MESSAGE="Homing completed"
    # Step 2: Auto-leveling
    # Step 3: Safely raise the Z-axis
    STATUS_MESSAGE="Raising Z-axis..."
    G90
    G0 Z5 F2000  # Raise slowly to prevent collisions
    # Step 4: Set timeout and temperature calibration
    SET_IDLE_TIMEOUT TIMEOUT={Temperature_Timeout_Duration}
    STATUS_MESSAGE="Starting temperature probe calibration..."
    TEMPERATURE_PROBE_CALIBRATE PROBE=fly_eddy_probe TARGET={desired_temperature} STEP={temperature_range_value}
    # Step 5: Set printing temperatures (modify as needed)
    STATUS_MESSAGE="Setting working temperatures..."
    SET_HEATER_TEMPERATURE HEATER=nozzle TARGET={max_temp}
    SET_HEATER_TEMPERATURE HEATER=bed TARGET={max_temp}
    # Completion message
    STATUS_MESSAGE="Temperature compensation process completed!"
    description: G-Code macro
EOF
)

GCODE_MACRO_CANCEL_TEMP_COMPENSATION=$(cat <<EOF
[gcode_macro CANCEL_TEMP_COMPENSATION]
description: Abort Temperature Compensation Process
gcode:
    SET_IDLE_TIMEOUT TIMEOUT=600  # Restore default timeout
    TURN_OFF_HEATERS
    M117 Calibration Aborted
EOF
)

GCODE_MACRO_BED_MESH_CALIBRATE=$(cat <<EOF
[gcode_macro BED_MESH_CALIBRATE]
rename_existing: _BED_MESH_CALIBRATE
gcode: 
       _BED_MESH_CALIBRATE horizontal_move_z=2 METHOD=rapid_scan {rawparams}
       G28 X Y
EOF
)

# ================================
# Function 1: Check if eddypz.cfg exists, delete it if it does, then recreate it with configuration content
# ================================

echo "Checking for eddypz.cfg file..."

if [ -f "$EDDPZ_CFG" ]; then
    echo "File exists: $EDDPZ_CFG"
    read -p "Do you want to delete the existing eddypz.cfg file and recreate it? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm "$EDDPZ_CFG"
        echo "Deleted file: $EDDPZ_CFG"
    else
        echo "Operation cancelled. Script terminated."
        exit 0
    fi
fi

# Create new eddypz.cfg and add configuration content
touch "$EDDPZ_CFG"
add_config() {
    local config_name=$1
    local config_content=$2

    echo "Processing config block: $config_name"
    IFS=$'\n' read -r -d '' -a LINES <<< "$config_content"

    for LINE in "${LINES[@]}"; do
        # Remove leading/trailing whitespace and escape special characters
        LINE_CLEAN=$(echo "$LINE" | sed 's/[][\.^$*]/\\&/g' | xargs)
        
        # Use grep to check if the entire line exists (ignoring leading/trailing whitespace)
        if ! grep -Fxq "^${LINE_CLEAN}$" "$EDDPZ_CFG"; then
            echo "$LINE" >> "$EDDPZ_CFG"
            echo "Added: $LINE"
        else
            echo "Already exists, skipping: $LINE"
        fi
    done

    # Add an empty line after each config block to ensure the last block also ends with a newline
    if ! grep -qxE '' "$EDDPZ_CFG"; then
        echo "" >> "$EDDPZ_CFG"
        echo "Added empty line"
    fi
}

# Add each config block
add_config "probe_eddy_current" "$PROBE_EDDY_CURRENT"
add_config "temperature_probe" "$TEMPERATURE_PROBE"
add_config "gcode_macro_CALIBRATE_EDDY" "$GCODE_MACRO_CALIBRATE_EDDY"
add_config "gcode_macro_TEMP_COMPENSATION" "$GCODE_MACRO_TEMP_COMPENSATION"
add_config "gcode_macro_CANCEL_TEMP_COMPENSATION" "$GCODE_MACRO_CANCEL_TEMP_COMPENSATION"
add_config "gcode_macro_BED_MESH_CALIBRATE" "$GCODE_MACRO_BED_MESH_CALIBRATE"
add_config "force_move" "$FORCE_MOVE"
echo "eddypz.cfg file has been updated."

# ================================
# Function 2: Add "[include eddypz.cfg] #eddy configuration" to printer.cfg if it doesn't already exist
# ================================
# Check if printer.cfg exists
if [ ! -f "$PRINTER_CFG" ]; then
    echo "Target file does not exist: $PRINTER_CFG"
    touch "$PRINTER_CFG"
    echo "Created new file: $PRINTER_CFG"
fi

# Normalize line endings to prevent mismatches due to Windows line endings
sed -i 's/\r$//' "$PRINTER_CFG"

# Define the search pattern with regex to allow whitespace around and ignore case
SEARCH_PATTERN='^\s*$$include\s*eddypz\.cfg$$\s*#\s*eddy\s*configuration\s*$'
SEARCH_PATTER='^\s*$$probe_eddy_current\s+fly_eddy_probe$$\s*$'

# Check if "[include eddypz.cfg] #eddy configuration" already exists
if grep -Eiq "$SEARCH_PATTERN" "$PRINTER_CFG"; then
    echo "[include eddypz.cfg] #eddy configuration already exists in $PRINTER_CFG, skipping addition."
else
    # Insert the new line at the beginning of the file
    sed -i "1i$PRINTER_CFG_CONTENT" "$PRINTER_CFG"
    echo "Added '[include eddypz.cfg] #eddy configuration' to the first line of $PRINTER_CFG"
fi

if grep -Eiq "$SEARCH_PATTER" "$PRINTER_CFG"; then
    echo "[probe_eddy_current fly_eddy_probe] already exists in $PRINTER_CFG, skipping addition."
else
    # Insert a new line at the beginning of the file.
    sed -i "2i$PRINTER_CFG_CONTEN" "$PRINTER_CFG"
    echo "Already added [probe_eddy_current fly_eddy_probe] to... $PRINTER_CFG "
fi

echo "All operations completed."
echo "Restarting Klipper service..."

# Restart Klipper service
sudo systemctl restart klipper

# Check if restart was successful
if systemctl is-active --quiet klipper; then
    echo "Klipper service restarted successfully."
else
    echo "Failed to restart Klipper service. Please check the logs for more information."
    exit 1
fi


# Error Handling Function: Output error message and exit
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Check if the specified file exists
if [ ! -f "$FILE" ]; then
    error_exit "File '$FILE' does not exist."
fi

# Check if the file is writable
if [ ! -w "$FILE" ]; then
    error_exit "File '$FILE' is not writable. Please check permissions."
fi

# Backup the original file
cp "$FILE" "${FILE}.bak" || error_exit "Failed to backup file '$FILE'."

# Perform replacement operation
sed -i 's/LDC1612_FREQ = 12000000/LDC1612_FREQ = 40000000/g' "$FILE" || error_exit "Replacement operation failed."

# Verify if replacement was successful
if grep -q "^LDC1612_FREQ = 40000000$" "$FILE"; then
    echo "Replacement successful: Found 'LDC1612_FREQ = 40000000'."
    exit 0
else
    error_exit "Replacement failed: 'LDC1612_FREQ = 40000000' not found."
fi

exit 0