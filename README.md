# UARTBootloader
This is a 512-bytes UART bootloader for AVR-family MCUs (ATmega) with 8-32 kBytes of the flash.

Project for **Atmel Studio 6.2**

Download **the flashing tool** from here: http://aterlux.ru/files/UARTFlasher.zip (Win32 executable)

Описание проекта на русском языке здесь: https://www.drive2.ru/b/2878717/

## Main features

* **The magic byte control**. The bootloader can check value of predefined byte in EEPROM, and jumps to the main firmware only if this value as expected.
The bootloader clears this EEPROM cell at the beggining of the flashing process, and can either set up the value by itself at the end of the process, or leave this to the main firmware.
The last option is useful to allow the firmware to complete some post-upgrade actions, and/or to ensure communication is still possible.   

* **The forced start**. If a condition for the forced start is met, bootloader do not jumps to the main firmware, and still waiting for comands. Next conditions are possible
  1. Low level on particular pin input (pull-up enabled)
  2. High level on particular pin input (external pull-down is required)
  3. A jumper between two pins
  4. Low level on two pins (pull-ups enabled)

* **Start on call**. The bootloader starts waiting for commands, if it called from the firmware. 
When power-up, or reset, and all conditions above are met (or those checks are disabled), the bootloader jumps to the main firmware.

* **The blinker**. The bootloader can output different blinking patterns onto a led, connected to particular pin, to indicate the mode of operation.

## How to use

1. Open the project in *Atmel Studio*
2. Go to project properties, *Device* tab, *Change Device* according to yours.
3. Open ***default_definitions.inc*** file and change definitions as you wish:
  * *HARDWARE_ID* - Exactly 14 characters that returned with blst reply, to identify a hardware. I reccomend to use combination of your nickname and the device name. For example: *"JnSmithBlinker"*
  * *F_CPU* - define the CPU frequency, as it enabled by hardware and the fuse settings
  * *UART_SPEED* - define the desired UART speed. Note: not all the speeds are exactly supported. Refer to the MCU datasheet
  * *UART_2X* - UART 2x mode (refer to the MCU datasheet): 1 - enabled, 0 - disabled
  * *UART_PARITY* - UART parity mode: 0 - none, 1 - odd, 2 - even
  * *UART_STOP_BITS* - number of stop bits: 1 or 2
  
  * *BLINKER* - enable blinker options: 1 - enable, 0 - disable
  * *BLINKER_DDR*, *BLINKER_PORT*, *BLINKER_PIN_NUM* - I/O registers and bit number to access blinker pin (if enabled)
  * *BLINKER_PATTERN_...* - different patterns of blinking (read description in the source)
  
  * *MAGIC* - a magic byte value, could not be 0xFF. Comment out the line to disable the magic byte control
  * *MAGIC_WRITE_WHEN_FLASHED* - 1 - if bootloader have to write the value itself, 0 - if it would be performed by the firmware.
  * *MAGIC_EEPROM_ADDRESS* - address in EEPROM, where magic value is stored.

  * *FORCE_METHOD* - a method for forced start: 0 - disabled, 1 - low level, 2 - high level (requires external pull-down), 3 - a jumper between two pins, 4 - low level on two pins
  * *FORCE_PORT*, *FORCE_DDR*, *FORCE_PIN*, *FORCE_PIN_NUM* - the I/O registers and bit number to access the pin
  * *FORCE_PORT2*, *FORCE_DDR2*, *FORCE_PIN2*, *FORCE_PIN_NUM2* - the same for the second pin, for methods 3 and 4
4. Setup the MCU fuses:
  * Select BOOTSZ bits to match the 256 words (512 bytes) bootloader size.
  * Set BOOTRST fuse bit (i.e. make it value of 0) - that makes the MCU to execute the bootloader first after reset.
5. Compile the project and flash it into MCU.
  
  

## Protocol description. 

All requests are started with bytes *0x42 0x4C* (**BL**), and replies with bytes *0x62 0x6C* (**bl**)
Reply *0x62 0x6C 0x65 0x72* (**bler**) means error (e.g. wrong command params, etc)
   
### BLST

Request to start flashing process

**Request:** *0x42 0x4C 0x53 0x54* (**BLST**) 

**Reply:** *0x62 0x6C 0x73 0x74 psw np <fwid>* (**blst...**) 
* *psw* - size of the flash page (in words)
* *np* - number of pages available (excluding bootloader area)
* *fwid* - 14 symbols to identify hardware

### BLPG

Flasing the page.

Before loading the first page, *BLST* must be performed.
The flashing process must always start from page 0 and page numbers must go sequentially
It is allowed to repeately perform *BLST* to start flashing process over again.


**Request:** *0x42 0x4C 0x50 0x47 pg `<data>` cc* (**BLPG...**) 
* *pg* - # of page `(0 <= *pg* < *np*)`
* *`<data>`* - *psw* * 2 bytes of page data 
* *cc* - CRC with polinomial x^8 +x^7 +x^6 +x^3 +x^2 +x +1 over all bytes in *`<data>`* field, MSB first, initialized with 0xFF:
```c         
    cc = 0xFF;
    for (i = 0; i < sizeof(data); i++) {
        cc ^= data[i];
        for (b = 0; b < 8; b++) {
            cc = ((cc & 0x80) ? 0xCF : 0) ^ (cc << 1);
        }
    }
```

**Reply:** *0x62 0x6C 0x70 0x77 pg* (**blpg.**) - page is successfully flashed

*0x62 0x6C 0x65 0x72* (**bler**) - cc byte doesn't match, or unexpected pg value

### BLXT

Finalize the flashing process and jump to the firmware

**Request:** *0x42 0x4C 0x58 0x54* (**BLXT**) 

**Reply:**  *0x62 0x6C 0x78 0x74* (**blxt**) 


## Have any questions?

Write me to: dmitry@aterlux.ru
