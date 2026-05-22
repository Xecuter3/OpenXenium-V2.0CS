<img width="960" height="1280" alt="IMG_2780 Large" src="https://github.com/user-attachments/assets/579e990c-6697-4552-b84e-ccbfc5b7a33f" />



# OpenXenium CPLD
 VERSION 2.0CS Fixed by Sick-Git

Additional Comments:

CS line is now utilised for OLED 20x4 data/command selection. This allows the OLED to be driven directly from the CPLD without needing to use the SCK line for this purpose which caused issues with timing and reliability.

CS line has been fixed to work with XeniumOS and TSOP booting. This was done by adding an extra state in the state machine to drive the CS line for an extra cycle after the address is latched.
This ensures it is active during the entire flash memory access which is required for XeniumOS and TSOP booting. The CS line is still released immediately for unsupported IO writes to avoid issues with other registers.

CPLD is at maximum capacity with this change, so some optimisations were made to fit it in.
The main one being the removal of the unused upper nibble of the REG_00EE_WRITE register which freed up enough macrocells to implement the extra state and logic for driving CS correctly.

Tested and verified working on real hardware by Sick-Git. 
All known features of the original Xenium are working correctly including bank switching, XeniumOS, TSOP booting, and the recovery switch.
The OLED is also working correctly with data/command selection using the CS line. Use the PICO/Feather RP2040 OLED Bridge in my repository to drive the OLED from a Raspberry Pi Pico or Feather RP2040 board. 
This allows for custom boot screens and diagnostics to be displayed on the OLED which is not possible with the original Xenium due to timing issues when sharing the SCK line.

Build and fit within Xilinx ISE 14.7 and then use iMpact to jtag your built .jed file to the CPLD.

Greets - Sick-Git.

<img width="960" height="1280" alt="IMG_2774 Large" src="https://github.com/user-attachments/assets/28c8d4d0-c8f8-4ce8-b85b-277afb0ca06f" />

<img width="960" height="1280" alt="IMG_2790 Large" src="https://github.com/user-attachments/assets/d1f6dde4-15a1-47da-b281-4fb7a2586c54" />

<img width="960" height="1280" alt="IMG_2773 Large" src="https://github.com/user-attachments/assets/0d731725-cf71-4ce3-a693-2cbe253bb762" />
