-- Design Name: openxenium
-- Module Name: openxenium - Behavioral
-- Project Name: OpenXenium. Open Source Xenius modchip CPLD replacement project
-- Target Devices: XC9572XL-10VQ64
--
-- VERSION 2.0CS Fixed by Sick-Git
--
-- Additional Comments:
-- CS line is now utilised for OLED 20x4 data/command selection. This allows the OLED to be driven directly from the CPLD without needing to use the SCK line for this purpose which caused issues with timing and reliability.
-- CS line has been fixed to work with XeniumOS and TSOP booting. This was done by adding an extra state in the state machine to drive the CS line for an extra cycle after the address is latched.
-- This ensures it is active during the entire flash memory access which is required for XeniumOS and TSOP booting. The CS line is still released immediately for unsupported IO writes to avoid issues with other registers.
-- CPLD is at maximum capacity with this change, so some optimisations were made to fit it in.
-- The main one being the removal of the unused upper nibble of the REG_00EE_WRITE register which freed up enough macrocells to implement the extra state and logic for driving CS correctly.
-- Tested and verified working on real hardware by Sick-Git. 
-- All known features of the original Xenium are working correctly including bank switching, XeniumOS, TSOP booting, and the recovery switch.
-- The OLED is also working correctly with data/command selection using the CS line. Use the PICO/Feather RP2040 OLED Bridge in my repository to drive the OLED from a Raspberry Pi Pico or Feather RP2040 board. 
-- This allows for custom boot screens and diagnostics to be displayed on the OLED which is not possible with the original Xenium due to timing issues when sharing the SCK line.
--
--
----------------------------------------------------------------------------------
--
--
--**BANK SELECTION**
--Bank selection is controlled by the lower nibble of address REG_00EF.
--A20,A19,A18 are address lines to the parallel flash memory.
--lines marked X means it is not forced by the CPLD for banking purposes.
--This is how is works:
--
--REGISTER 0xEF Bank Commands:
--BANK NAME                  DATA BYTE    A20|A19|A18 ADDRESS OFFSET
--TSOP                       XXXX 0000     X |X |X    N/A.     (This locks up the Xenium to force it to boot from TSOP.)
--XeniumOS(c.well loader)    XXXX 0001     1 |1 |0    0x180000 (This is the default boot state. Contains Cromwell bootloader)
--XeniumOS                   XXXX 0010     1 |0 |X    0x100000 (This is a 512kb bank and contains XeniumOS)
--BANK1 (USER BIOS 256kB)    XXXX 0011     0 |0 |0    0x000000
--BANK2 (USER BIOS 256kB)    XXXX 0100     0 |0 |1    0x040000
--BANK3 (USER BIOS 256kB)    XXXX 0101     0 |1 |0    0x080000
--BANK4 (USER BIOS 256kB)    XXXX 0110     0 |1 |1    0x0C0000
--BANK1 (USER BIOS 512kB)    XXXX 0111     0 |0 |X    0x000000
--BANK2 (USER BIOS 512kB)    XXXX 1000     0 |1 |X    0x080000
--BANK1 (USER BIOS 1MB)      XXXX 1001     0 |X |X    0x000000
--RECOVERY (NOTE 1)          XXXX 1010     1 |1 |1    0x1C0000
--
--
--NOTE 1: The RECOVERY bank can also be actived by the physical switch on the Xenium. This forces bank ten (0b1010) on power up.
--This bank also contains non-volatile storage of settings an EEPROM backup in the smaller sectors at the end of the flash memory.
--The memory map is shown below:
--     (1C0000 to 1DFFFF PROTECTED AREA 128kbyte recovery bios)
--     (1E0000 to 1FBFFF Additional XeniumOS Data)
--     (1FC000 to 1FFFFF Contains eeprom backup, XeniumOS settings)
--
--
--**XENIUM CONTROL WRITE/READ REGISTERS**
--Bits marked 'X' either have no function or an unknown function.
--**0xEF WRITE:**
--X,SCK,CS,MOSI,BANK[3:0]
--
--**0xEF READ:**
--RECOV SWITCH POSITION (0=ACTIVE),X,MISO(Pin 1),MISO (Pin 4),BANK[3:0]
--
--**0xEE (WRITE)**
--X,X,X,X X,B,G,R (DEFAULT LED ON POWER UP IS RED)
--
--**0xEE (READ)**
--Just returns 0x55 on a real xenium?
--

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
ENTITY openxenium IS
   PORT (
      HEADER_1 : IN STD_LOGIC;
      HEADER_4 : IN STD_LOGIC;
      HEADER_CS : OUT STD_LOGIC;
      HEADER_SCK : OUT STD_LOGIC;
      HEADER_MOSI : OUT STD_LOGIC;
      HEADER_LED_R : OUT STD_LOGIC;
      HEADER_LED_G : OUT STD_LOGIC;
      HEADER_LED_B : OUT STD_LOGIC;

      FLASH_WE : OUT STD_LOGIC;
      FLASH_OE : OUT STD_LOGIC;
      FLASH_ADDRESS : OUT STD_LOGIC_VECTOR (20 DOWNTO 0);
      FLASH_DQ : INOUT STD_LOGIC_VECTOR (7 DOWNTO 0);

      LPC_LAD : INOUT STD_LOGIC_VECTOR (3 DOWNTO 0);
      LPC_CLK : IN STD_LOGIC;
      LPC_RST : IN STD_LOGIC;

      XENIUM_RECOVERY : IN STD_LOGIC; -- Recovery is active low and requires an external Pull-up to 3.3V
      XENIUM_D0 : OUT STD_LOGIC
   );

END openxenium;

ARCHITECTURE Behavioral OF openxenium IS

   TYPE LPC_STATE_MACHINE IS (
   WAIT_START,
   CYCTYPE_DIR,
   ADDRESS,
   WRITE_DATA,
   READ_DATA0,
   READ_DATA1,
   TAR2,
   SYNCING,
   TAR_EXIT
   );

   TYPE CYC_TYPE IS (
   IO_READ, --Default state
   IO_WRITE,
   MEM_READ,
   MEM_WRITE
   );

   SIGNAL LPC_CURRENT_STATE : LPC_STATE_MACHINE;
   SIGNAL CYCLE_TYPE : CYC_TYPE;

   SIGNAL LPC_ADDRESS : STD_LOGIC_VECTOR (20 DOWNTO 0); --LPC Address is actually 32bits for memory IO, but we only need 21.

   --XENIUM IO REGISTERS. BITS MARKED 'X' HAVE AN UNKNOWN FUNCTION OR ARE UNUSED. NEEDS MORE RE.
   --Bit masks are all shown upper nibble first.

   --IO WRITE/READ REGISTERS SIGNALS
   CONSTANT REG_00EE_READ        : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101"; -- Genuine Xenium
   CONSTANT XENIUM_IO_BASE      : STD_LOGIC_VECTOR (6 DOWNTO 0) := "1110111";  -- bits[7:1] of IO addr 0xEE/0xEF
   CONSTANT LPC_D0_RELEASE_ADDR : STD_LOGIC_VECTOR (7 DOWNTO 0) := x"74";     -- address at which D0 is released
   SIGNAL REG_00EE_WRITE : STD_LOGIC_VECTOR (2 DOWNTO 0) := "001"; --B,G,R only. Bits 7:3 are unused, removed to free macrocells.
   SIGNAL REG_00EF_WRITE : STD_LOGIC_VECTOR (6 DOWNTO 0) := "0000001"; --SCK[6],CS[5],MOSI[4],BANK[3:0]. Bit 7 unused, removed to free macrocells.
   SIGNAL REG_00EF_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101"; --Input signal
   SIGNAL READBUFFER : STD_LOGIC_VECTOR (7 DOWNTO 0); --I buffer Memory and IO reads to reduce pin to pin delay in CPLD which caused issues

   --R/W SIGNAL FOR FLASH MEMORY
   SIGNAL sFLASH_DQ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "ZZZZZZZZ";

   --TSOPBOOT IS SET TO '1' WHEN YOU REQUEST TO BOOT FROM TSOP. THIS PREVENTS THE CPLD FROM DRIVING D0.
   --D0LEVEL is inverted and connected to the D0 output pad. This allows the CPLD to latch/release the D0/LFRAME signal.
   SIGNAL TSOPBOOT : STD_LOGIC := '0';
   SIGNAL D0LEVEL : STD_LOGIC := '0';

   --GENERIC COUNTER USED TO TRACK ADDRESS AND SYNC COUNTERS.
   SIGNAL COUNT : INTEGER RANGE 0 TO 7;

BEGIN
   --ASSIGN THE IO TO SIGNALS BASED ON REQUIRED BEHAVIOUR
   HEADER_CS   <= REG_00EF_WRITE(5);
   HEADER_SCK  <= REG_00EF_WRITE(6);
   HEADER_MOSI <= REG_00EF_WRITE(4);

   HEADER_LED_R <= REG_00EE_WRITE(0);
   HEADER_LED_G <= REG_00EE_WRITE(1);
   HEADER_LED_B <= REG_00EE_WRITE(2);

   FLASH_ADDRESS <= LPC_ADDRESS;

   --LAD lines can be either input or output
   --The output values depend on variable states of the LPC transaction
   --Refer to the Intel LPC Specification Rev 1.1
   LPC_LAD <= "0000" WHEN LPC_CURRENT_STATE = SYNCING AND COUNT = 0 ELSE
              "0101" WHEN LPC_CURRENT_STATE = SYNCING ELSE
              "1111" WHEN LPC_CURRENT_STATE = TAR2 ELSE
              "1111" WHEN LPC_CURRENT_STATE = TAR_EXIT ELSE
              READBUFFER(3 DOWNTO 0) WHEN LPC_CURRENT_STATE = READ_DATA0 ELSE --This has to be lower nibble first!
              READBUFFER(7 DOWNTO 4) WHEN LPC_CURRENT_STATE = READ_DATA1 ELSE
              "ZZZZ";

   --FLASH_DQ is mapped to the data byte sent by the Xbox in MEM_WRITE mode, else its just an input
   FLASH_DQ <= sFLASH_DQ WHEN CYCLE_TYPE = MEM_WRITE ELSE "ZZZZZZZZ";

   --Write Enable for Flash Memory Write (Active low)
   --Minimum pulse width 90ns.
   --Address is latched on the falling edge of WE.
   --Data is latched on the rising edge of WE.
   FLASH_WE <= '0' WHEN CYCLE_TYPE = MEM_WRITE AND
               (LPC_CURRENT_STATE = TAR2 OR
               LPC_CURRENT_STATE = SYNCING) ELSE '1';

   --Output Enable for Flash Memory Read (Active low)
   --Output Enable must be pulled low for 50ns before data is valid for reading
   FLASH_OE <= '0' WHEN CYCLE_TYPE = MEM_READ AND
               (LPC_CURRENT_STATE = TAR2 OR
               LPC_CURRENT_STATE = SYNCING OR
               LPC_CURRENT_STATE = READ_DATA0 OR
               LPC_CURRENT_STATE = READ_DATA1 OR
               LPC_CURRENT_STATE = TAR_EXIT) ELSE '1';

   --D0 has the following behaviour
   --Held low on boot to ensure it boots from the LPC then released when definitely booting from modchip.
   --When soldered to LFRAME it will simulate LPC transaction aborts for 1.6.
   --Released for TSOP booting.
   --NOTE: XENIUM_D0 is an output to a mosfet driver. '0' turns off the MOSFET releasing D0
   --and a value of '1' turns on the MOSFET forcing it to ground. This is why I invert D0LEVEL before mapping it.
   XENIUM_D0 <= '0' WHEN TSOPBOOT = '1' ELSE
                '1' WHEN CYCLE_TYPE = MEM_READ ELSE
                '1' WHEN CYCLE_TYPE = MEM_WRITE ELSE
                NOT D0LEVEL;

   REG_00EF_READ <= XENIUM_RECOVERY & '0' & HEADER_4 & HEADER_1 & REG_00EF_WRITE(3 DOWNTO 0);

PROCESS (LPC_CLK, LPC_RST, TSOPBOOT) BEGIN

   IF (LPC_RST = '0') THEN
      --LPC_RST goes low during boot up or hard reset.
      --We need to set D0 only if not TSOP booting.
      D0LEVEL <= TSOPBOOT;
      CYCLE_TYPE <= IO_READ;
      LPC_CURRENT_STATE <= WAIT_START;

   ELSIF (rising_edge(LPC_CLK)) THEN
      CASE LPC_CURRENT_STATE IS
         WHEN WAIT_START =>
            IF LPC_LAD = "0000" AND TSOPBOOT = '0' THEN
               LPC_CURRENT_STATE <= CYCTYPE_DIR;
            END IF;
         WHEN CYCTYPE_DIR =>

            LPC_CURRENT_STATE <= ADDRESS;

            IF LPC_LAD(3 DOWNTO 1) = "000" THEN
               CYCLE_TYPE <= IO_READ;
               COUNT <= 3;
            ELSIF LPC_LAD(3 DOWNTO 1) = "001" THEN
               CYCLE_TYPE <= IO_WRITE;
               COUNT <= 3;
            ELSIF LPC_LAD(3 DOWNTO 1) = "010" THEN
               CYCLE_TYPE <= MEM_READ;
               COUNT <= 7;
            ELSIF LPC_LAD(3 DOWNTO 1) = "011" THEN
               CYCLE_TYPE <= MEM_WRITE;
               COUNT <= 7;
            ELSE
               LPC_CURRENT_STATE <= WAIT_START; -- Unsupported, reset state machine.
            END IF;

         --ADDRESS GATHERING
         WHEN ADDRESS =>

            IF COUNT = 5 THEN
               LPC_ADDRESS(20) <= LPC_LAD(0);
            ELSIF COUNT = 4 THEN
               LPC_ADDRESS(19 DOWNTO 16) <= LPC_LAD;
               --BANK CONTROL
               -- Set recovery bank if switch is activated
               IF XENIUM_RECOVERY = '0' AND TSOPBOOT = '0' AND D0LEVEL = '0' THEN
                  REG_00EF_WRITE(3 DOWNTO 0) <= "1010";
               END IF;
               CASE REG_00EF_WRITE(3 DOWNTO 0) IS
                  WHEN "0001" =>
                     LPC_ADDRESS(20 DOWNTO 18) <= "110"; --256kb bank
                  WHEN "0010" =>
                     LPC_ADDRESS(20 DOWNTO 19) <= "10"; --512kb bank
                  WHEN "0011" =>
                     LPC_ADDRESS(20 DOWNTO 18) <= "000"; --256kb bank
                  WHEN "0100" =>
                     LPC_ADDRESS(20 DOWNTO 18) <= "001"; --256kb bank
                  WHEN "0101" =>
                     LPC_ADDRESS(20 DOWNTO 18) <= "010"; --256kb bank
                  WHEN "0110" =>
                     LPC_ADDRESS(20 DOWNTO 18) <= "011"; --256kb bank
                  WHEN "0111" =>
                     LPC_ADDRESS(20 DOWNTO 19) <= "00"; --512kb bank
                  WHEN "1000" =>
                     LPC_ADDRESS(20 DOWNTO 19) <= "01"; --512kb bank
                  WHEN "1001" =>
                     LPC_ADDRESS(20) <= '0'; --1mb bank
                  WHEN "1010" =>
                     LPC_ADDRESS(20 DOWNTO 18) <= "111"; --256kb bank
                  WHEN "0000" =>
                     --Bank zero will disable modchip and release D0 and reset state machine.
                     LPC_CURRENT_STATE <= WAIT_START;
                     TSOPBOOT <= '1';
                  WHEN OTHERS =>
               END CASE;
            ELSIF COUNT = 3 THEN
               LPC_ADDRESS(15 DOWNTO 12) <= LPC_LAD;
            ELSIF COUNT = 2 THEN
               LPC_ADDRESS(11 DOWNTO 8) <= LPC_LAD;
            ELSIF COUNT = 1 THEN
               LPC_ADDRESS(7 DOWNTO 4) <= LPC_LAD;
            ELSIF COUNT = 0 THEN
               LPC_ADDRESS(3 DOWNTO 0) <= LPC_LAD;

               LPC_CURRENT_STATE <= WAIT_START;

               -- catch unsupported IO read/writes here before they modify LAD
               IF CYCLE_TYPE = MEM_READ THEN
                  LPC_CURRENT_STATE <= TAR2;
               ELSIF CYCLE_TYPE = MEM_WRITE THEN
                  LPC_CURRENT_STATE <= WRITE_DATA;
               ELSIF LPC_ADDRESS(7 DOWNTO 1) = XENIUM_IO_BASE THEN   -- check if supported Xenium register (EE or EF), the last bit is irrelevant

                  IF CYCLE_TYPE = IO_READ THEN
                     LPC_CURRENT_STATE <= TAR2;
                  ELSIF CYCLE_TYPE = IO_WRITE THEN
                     LPC_CURRENT_STATE <= WRITE_DATA;
                  END IF;

               END IF;

            END IF;
            COUNT <= COUNT - 1;

         -- MEMORY OR IO WRITES. These all happen lower nibble first. (Refer to Intel LPC spec)
         -- HACK: abuses counter rollover from previous state
         WHEN WRITE_DATA =>

            IF CYCLE_TYPE = MEM_WRITE THEN

               IF COUNT = 7 THEN
                  sFLASH_DQ(3 DOWNTO 0) <= LPC_LAD;
               ELSE
                  sFLASH_DQ(7 DOWNTO 4) <= LPC_LAD;
               END IF;

            ELSE

               -- it's already been confirmed this is a supported Xenium register in a previous state
               -- so only a single bit needs to be checked to differentiate between the two
               IF LPC_ADDRESS(0) = '0' THEN

                  -- REG_00EE: only lower nibble bits 2:0 (B,G,R) are meaningful; upper nibble and bit 3 unused.
                  IF COUNT = 7 THEN
                     REG_00EE_WRITE(2 DOWNTO 0) <= LPC_LAD(2 DOWNTO 0);
                  END IF;
               ELSE
                  IF COUNT = 7 THEN
                     REG_00EF_WRITE(3 DOWNTO 0) <= LPC_LAD;
                  ELSE
                     -- REG_00EF upper nibble: bit6=SCK, bit5=CS, bit4=MOSI. bit7 unused, not stored.
                     REG_00EF_WRITE(6 DOWNTO 4) <= LPC_LAD(2 DOWNTO 0);
                  END IF;

               END IF;

            END IF;

            IF COUNT = 6 THEN
               LPC_CURRENT_STATE <= TAR2;
            END IF;
            COUNT <= COUNT - 1;

         --MEMORY OR IO READS
         WHEN READ_DATA0 =>
            LPC_CURRENT_STATE <= READ_DATA1;
         WHEN READ_DATA1 =>
            LPC_CURRENT_STATE <= TAR_EXIT;

         --TURN BUS AROUND (HOST TO PERIPHERAL)
         WHEN TAR2 =>
            LPC_CURRENT_STATE <= SYNCING;
            COUNT <= 2;

         --SYNCING STAGE
         WHEN SYNCING =>
            COUNT <= COUNT - 1;
            --Buffer IO reads during syncing. Helps output timings.
            --On COUNT=1 (second-to-last cycle) latch the read data so it is ready when LAD switches to "0000".
            IF COUNT = 1 THEN
               IF CYCLE_TYPE = MEM_READ THEN
                  READBUFFER <= FLASH_DQ;
               ELSIF CYCLE_TYPE = IO_READ THEN
                  IF LPC_ADDRESS(0) = '0' THEN
                     READBUFFER <= REG_00EE_READ;
                  ELSE
                     READBUFFER <= REG_00EF_READ;
                  END IF;
               END IF;
            END IF;
            IF COUNT = 0 THEN
               -- SYNC_COMPLETE merged here: COUNT=0 means sync done, drive "0000" on LAD (handled combinatorially above)
               IF CYCLE_TYPE = MEM_READ OR CYCLE_TYPE = IO_READ THEN
                  LPC_CURRENT_STATE <= READ_DATA0;
               ELSE
                  LPC_CURRENT_STATE <= TAR_EXIT;
               END IF;
            END IF;

         --TURN BUS AROUND (PERIPHERAL TO HOST)
         WHEN TAR_EXIT =>
            --D0 is held low until a few memory reads
            --This ensures it is booting from the modchip. Genuine Xenium arbitrarily
            --releases after the 5th read. This is always address 0x74
            IF LPC_ADDRESS(7 DOWNTO 0) = LPC_D0_RELEASE_ADDR THEN
               D0LEVEL <= '1';
            END IF;

            CYCLE_TYPE <= IO_READ;
            LPC_CURRENT_STATE <= WAIT_START;

         WHEN OTHERS =>
            -- Safety net: undefined FSM state returns to idle.
            LPC_CURRENT_STATE <= WAIT_START;
      END CASE;
   END IF;
END PROCESS;
END Behavioral;
