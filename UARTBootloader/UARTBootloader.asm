/*
 * UARTBootloader.asm
 *
 *  Created: 13.03.2016
 *  Author: Dmitry Pogrebnyak (http://aterlux.ru/)
 */ 

/* Описание протокола. Все запросы начинаются с байтов  0x42 0x4C (BL), а ответы с байтов 0x62 0x6C (bl)
   Ответ 0x62 0x6C 0x65 0x72 (bler) означает ошибку (напр, в параметрах команды)
   
   Запрос: 0x42 0x4C 0x53 0x54 (BLST) запрос на начало работы загрузчика
   Ответ: 0x62 0x6C 0x73 0x74 psw np <fwid> (blst...) 
         psw - размер страницы флеш-памяти в словах
         np - количество доступных для программирования страниц (не считая загрузчика)
         fwid - 14 символов с идентифицирующим кодом

   Запрос: 0x42 0x4C 0x50 0x47 pg <data> cc (BLPG...) загрузка и прошивка страницы с номером pgn
         pg - номер страницы (0 <= pg < np)
         <data> - psw * 2 байт данных страницы
         cc - CRC с полиномом x^8 +x^7 +x^6 +x^3 +x^2 +x +1 по всем байтам в поле data, сначала старший бит, инициализированное значением 0xFF:
              cc = 0xFF;
              for (i = 0; i < sizeof(data); i++) {
                cc ^= data[i];
                for (b = 0; b < 8; b++) {
                   cc = ((cc & 0x80) ? 0xCF : 0) ^ (cc << 1);
                }
              } 

         процессу загрузки должен предшествовать вызов команды BLST
         процесс загрузки должен всегда начинаться со страницы 0 и номера страниц должны идти по-порядку.
         допустимо повторно вызвать BLST и начать загрузку заново 
   Ответ: 0x62 0x6C 0x70 0x77 pg (blpg.) - OK
          0x62 0x6C 0x65 0x72 (bler) - не совпал контрольный байт, или номер страницы отличается от ожидаемого

   Запрос: 0x42 0x4C 0x58 0x54 (BLXT) - завершить процесс прошивки и перейти к программе
   Ответ:  0x62 0x6C 0x78 0x74 (blxt) 

   
   Protocol description. All requests are started with bytes 0x42 0x4C (BL), and replies with bytes 0x62 0x6C (bl)
   Answer 0x62 0x6C 0x65 0x72 (bler) means error (e.g. wrong command params, etc)
   
   Request: 0x42 0x4C 0x53 0x54 (BLST) request to start flashing process
   Reply: 0x62 0x6C 0x73 0x74 psw np <fwid> (blst...) 
         psw - size of the flash page (in words)
         np - number of pages available (excluding bootloader area)
         fwid - 14 symbols to identify hardware

   Request: 0x42 0x4C 0x50 0x47 pg <data> cc (BLPG...) flasing the page #pg
         pg - # of page (0 <= pg < np)
         <data> - psw * 2 bytes of page data 
         cc - CRC with polinomial x^8 +x^7 +x^6 +x^3 +x^2 +x +1 over all bytes in <data> field, MSB first, initialized with 0xFF:
              cc = 0xFF;
              for (i = 0; i < sizeof(data); i++) {
                cc ^= data[i];
                for (b = 0; b < 8; b++) {
                   cc = ((cc & 0x80) ? 0xCF : 0) ^ (cc << 1);
                }
              } 

         before loading the first page, BLST must be performed
         The flashing process must always start from page 0 and page numbers must go sequentially
         It is allowed to repeately perform BLST to start flashing process over again
   Reply: 0x62 0x6C 0x70 0x77 pg (blpg.) - OK
          0x62 0x6C 0x65 0x72 (bler) - cc byte doesn't match, or unexpected pg value

   Request: 0x42 0x4C 0x58 0x54 (BLXT) - finalize the flashing process and jump to the firmware
   Reply:  0x62 0x6C 0x78 0x74 (blxt) 
*/

.include "default_definitions.inc"

/**********************************************************************************************************************************/
// Проверки и предварительные вычисления / Checks and precalculations

.ifndef UART_2X
   .equ UART_2X = 0
   .warning "UART_2X is not defined. Defaults to 0 (disabled)"
.elif ((UART_2X != 0) && (UART_2X != 1))
   .error "UART_2X should be either 1 or 0"
.endif

.ifndef UART_PARITY
   .equ UART_PARITY = 0
   .warning "UART_PARITY is not defined. Defaults to 0 (disabled)"
.elif (UART_PARITY != 0) && (UART_PARITY != 1)  && (UART_PARITY != 2)
   .error "UART_PARITY should be 0, 1 or 2"
.endif

.ifndef F_CPU 
   .equ F_CPU = 8000000
   .warning "F_CPU is not defined. Defaults to 8MHz"
.endif

.ifndef UART_SPEED
   .equ UART_SPEED = 9600
   .warning "UART_SPEED is not defined. Defaults to 9600"
.endif

.if (F_CPU < 1000000) || (F_CPU > 20000000) 
   .warning "Suspicious F_CPU setting. Please check"
.endif

.if (UART_SPEED < 1200) || (UART_SPEED > 1000000)
   .warning "Suspicious UART_SPEED setting. Please check"
.endif

.equ UBRR_value = ((F_CPU / 8 / ((UART_2X == 1) ? 1 : 2) + UART_SPEED / 2) / UART_SPEED > 0) ?  ((F_CPU / 8 / ((UART_2X == 1) ? 1 : 2) + UART_SPEED / 2) / UART_SPEED) - 1 : 0

.if UBRR_value > 4095
   .error "UART_SPEED too small. Try to increase and/or set UART_2X = 0"
.endif

.equ UART_SPEED_actual = (F_CPU / 8 / ((UART_2X == 1) ? 1 : 2) + (UBRR_VALUE + 1) / 2) / (UBRR_VALUE + 1)

.equ UART_SPEED_difference_mil = (abs(UART_SPEED - UART_SPEED_actual) * 1000 + UART_SPEED / 2) / UART_SPEED

.if UART_SPEED_difference_mil > ((!defined(UART_PARITY) || (UART_PARITY == 0)) ? 45 : 41)
  .error "The actual speed of UART critically differs from defined. Communication impossible. Try to set UART_2X = 1 and/or change the UART_SPEED value"
.elif UART_SPEED_difference_mil > 30
  .warning "The actual speed of UART will differ more than 3 percents from defined! This may cause communication errors. Try to set UART_2X = 1 and/or change the UART_SPEED value"
.elif UART_SPEED_difference_mil > 21
  .warning "The actual speed of UART will differ more than 2.1 percents from defined. Try to set UART_2X = 1"
.endif

.ifdef MAGIC
  .if ((MAGIC >= 0xFF) || (MAGIC < 0))
    .error "MAGIC should by a byte value less than 0xFF"
  .endif
.endif

.ifndef BLINKER
  .equ BLINKER = 0
.endif


.equ BOOTLOADER_SIZE_WORDS = 0x100
.equ BOOTLOADER_OFFSET_WORDS = (FLASHEND + 1 - BOOTLOADER_SIZE_WORDS)

.equ PAGES_AVAILABLE = BOOTLOADER_OFFSET_WORDS / PAGESIZE

.if defined(SELFPRGEN) && !defined(SPMEN)
  .equ SPMEN = SELFPRGEN
.endif


/**********************************************************************************************************************************/
// Основной код загрузчика / Bootloader body

// r16, r17, r22, r23 - временные/параметры
// r18 - текущее состояние
// r20, r19 - временные вне процедур
// r28 - при выполнении uart_read побитно выполняется "или" со значением регистра UCSR0A/UCSRA
// r31:r30 - адрес для прошивки
// r27 - паттерн блинкера, r26 - счётчик блинкера
// r25:r24 - круговой счётчик
// r3 - текущая страница



.equ state_enter = 0 // Сразу после входа, BLPG запрещено
.equ state_ready = 1 // После BLST, программирование разрешено
.equ state_flashing = 2 // Была выполнена хотя бы одна BLPG


.org BOOTLOADER_OFFSET_WORDS
boot_loader:

cli
ldi r16, high(RAMEND)
out SPH, r16
ldi r16, low(RAMEND)
out SPL, r16

rcall wait_eeprom_finish

rcall clear_ports // на выходе r16 == 0

////////// Проверка условий на запуск бутлоадера

// 1. Проверка и сброс MCUSR (MCUCSR): если в нём нет установленных флагов, значит бутлоадер вызван переходом из программы
.ifdef MCUSR
  in r17, MCUSR
  out MCUSR, r16
.else
  in r17, MCUCSR
  out MCUCSR, r16
.endif

tst r17
breq enter_bootloader

.ifdef GPIOR0
  out GPIOR0, r17
.else
  sts SRAM_START, r17
.endif

// 2. Проверка маркера
.ifdef MAGIC 


  rcall load_magic_eear
  sbi EECR, EERE
  in r16, EEDR
  cpi r16, MAGIC
  brne enter_bootloader
.endif


// 3. Проверка уровня на входах
.ifdef FORCE_METHOD
  .if (FORCE_METHOD == 1) // Первый метод: низкий уровень на пине (включается пулл-ап)
    sbi FORCE_PORT, FORCE_PIN_NUM
    ldi r16, 255
    test_loop1:
      sbic FORCE_PIN, FORCE_PIN_NUM
      rjmp not_forced
      dec r16
    brne test_loop1
    rjmp enter_bootloader
    not_forced1:

  .elif (FORCE_METHOD == 2) // Второй метод: высокий уровень на пине 
    ldi r16, 255
    test_loop1:
      sbis FORCE_PIN, FORCE_PIN_NUM
      rjmp not_forced
      dec r16
    brne test_loop1
    rjmp enter_bootloader

  .elif FORCE_METHOD == 3 // Третий метод: два пина замкнуты перемычкой
    // Включим подтяжку и проверим что на обоих пинах высокий уровень
    sbi FORCE_PORT, FORCE_PIN_NUM
    sbi FORCE_PORT2, FORCE_PIN_NUM2
    rjmp PC+1 // Пауза 2 такта
    sbic FORCE_PIN, FORCE_PIN_NUM
    sbis FORCE_PIN2, FORCE_PIN_NUM2
      rjmp not_forced

    // На первый пин выдадим низкий уровень и проверим что низкий уровень на втором пине
    cbi FORCE_PORT, FORCE_PIN_NUM
    sbi FORCE_DDR,  FORCE_PIN_NUM
    rjmp PC+1 // Пауза 2 такта
    sbic FORCE_PIN2, FORCE_PIN_NUM2
      rjmp not_forced

    // Включаем подтяжку обратно и проверяем что у нас по-прежнему читается высокий уровень
    cbi FORCE_DDR,  FORCE_PIN_NUM
    sbi FORCE_PORT, FORCE_PIN_NUM
    rjmp PC+1 // Пауза 2 такта
    sbic FORCE_PIN, FORCE_PIN_NUM
    sbis FORCE_PIN2, FORCE_PIN_NUM2
      rjmp not_forced

    // На второй пин выдадим низкий уровень и проверим что низкий уровень на первом пине
    cbi FORCE_PORT2, FORCE_PIN_NUM2
    sbi FORCE_DDR2,  FORCE_PIN_NUM2
    rjmp PC+1 // Пауза 2 такта
    sbis FORCE_PIN, FORCE_PIN_NUM
    rjmp enter_bootloader


    // Очевидно, пины замкнуты меж собой. Переходим к бутлоадеру
     
  .elif (FORCE_METHOD == 4) // Четвёртый метод: низкий уровень на двух пинах (включаются пулл-апы)
    sbi FORCE_PORT, FORCE_PIN_NUM
    sbi FORCE_PORT2, FORCE_PIN_NUM2
    ldi r16, 255
    test_loop1:
      sbis FORCE_PIN, FORCE_PIN_NUM
      sbic FORCE_PIN2, FORCE_PIN_NUM2
      rjmp not_forced
      dec r16
    brne test_loop1
    rjmp enter_bootloader
    not_forced1:
  .endif
 not_forced:
.endif

jump_to_firmware:
 rcall clear_ports // r16 == 0 на выходе
 //stop UART
 .ifdef UCSR0B
   sts UCSR0B, r16
 .else
   out UCSRB, r16
 .endif
 .if FLASHEND < 0x1000 // у устройств с 8k отсутствует инструкция jmp
 rjmp 0x0000
 .else
 jmp 0x0000
 .endif


enter_bootloader:

// Инициализация USART
.ifdef UCSR0A
  ldi r16, ((UART_2X == 1) ? (1 << U2X0) : 0)
  sts UCSR0A, r16
  ldi r16, low(UBRR_VALUE)
  sts UBRR0L, r16
  ldi r16, high(UBRR_VALUE)
  sts UBRR0H, r16
  ldi r16, (1 << RXEN0) | (1 << TXEN0)
  sts UCSR0B, r16
  ldi r16, (1 << UCSZ01) | (1 << UCSZ00) | ((UART_PARITY == 1) ? ((1 << UPM01) | (1 << UPM00)) : ((UART_PARITY == 2) ? (1 << UPM01) : 0)) | ((UART_STOP_BITS == 2) ? (1 << USBS0) : 0)
  sts UCSR0C, r16
.else
  // вариант регистров ATmega8 
  ldi r16, ((UART_2X == 1) ? (1 << U2X) : 0)
  out UCSRA, r16
  ldi r16, low(UBRR_VALUE)
  out UBRRL, r16
  ldi r16, high(UBRR_VALUE)
  out UBRRH, r16
  ldi r16, (1 << RXEN) | (1 << TXEN)
  out UCSRB, r16
  .ifdef URSEL
    ldi r16, (1 << URSEL) | (1 << UCSZ1) | (1 << UCSZ0) | ((UART_PARITY == 1)  ? ((1 << UPM1) | (1 << UPM0)) : ((UART_PARITY == 2) ? (1 << UPM1) : 0)) | ((UART_STOP_BITS == 2) ? (1 << USBS) : 0)
  .else
    ldi r16, (1 << UCSZ1) | (1 << UCSZ0) | ((UART_PARITY == 1)  ? ((1 << UPM1) | (1 << UPM0)) : ((UART_PARITY == 2) ? (1 << UPM1) : 0)) | ((UART_STOP_BITS == 2) ? (1 << USBS) : 0)
  .endif
  out UCSRC, r16
.endif


ldi r18, state_enter
.if BLINKER == 1
  sbi BLINKER_DDR, BLINKER_PIN_NUM

  ldi r27, BLINKER_PATTERN_NORMAL
  clr r26
.endif

/***************/
// Цикл ожидания команд

// BLST - вход в режим программирования
// BLPG - данные страницы (1 байт № страницы + n байт страница + 1 байт - контроль)
// BLXT - завершение программирования
main_loop:
  rcall uart_read
  test_b:
    cpi r16, 'B'
	brne main_loop
  rcall uart_read
  cpi r16, 'L'
  brne test_b

  rcall uart_read
  cpi r16, 'S'
  breq test_blst
  cpi r16, 'P'
  breq test_blpg
  cpi r16, 'X'
  brne test_b
test_blxt:
  rcall uart_read
  cpi r16, 'T'
  brne test_b
  // выход из загрузчика 
  cpi r18, state_flashing
  brne blxt_exit

    ldi r16, (1 << RWWSRE) | (1 << SPMEN)
    rcall do_spm
    .ifdef MAGIC
      .if MAGIC_WRITE_WHEN_FLASHED == 1 
        ldi r16, MAGIC
        rcall write_magic
      .endif
    .endif
blxt_exit:
  .ifdef UCSR0A
    ldi r16, (1 << TXC0) | ((UART_2X == 1) ? (1 << U2X0) : 0) 
    sts UCSR0A, r16
  .else
    sbi UCSRA, TXC
  .endif
  ldi r22, 'x'
  ldi r23, 't'
  rcall uart_blrep
  wait_transmission_complete:
    .ifdef UCSR0A
      lds r16, UCSR0A
      sbrs r16, TXC0
    .else
      sbis UCSRA, TXC
    .endif
    rjmp wait_transmission_complete
  rjmp jump_to_firmware


test_blst:   
  rcall uart_read
  cpi r16, 'T'
  brne test_b

  cpi r18, state_flashing
  brne blst_finish
    ldi r16, (1 << RWWSRE) | (1 << SPMEN)
    rcall do_spm
  blst_finish:
  .if BLINKER == 1
    ldi r27, BLINKER_PATTERN_READY
  .endif
  ldi r18, state_ready
  clr r3
  ldi r22, 's'
  ldi r23, 't'
  rcall uart_blrep

  ldi r30, low(bootloader_id * 2)
  ldi r31, high(bootloader_id * 2)
  ldi r20, 16
  blst_info_loop:
    lpm r16, Z+
    rcall uart_write
    dec r20 
    brne blst_info_loop

  rjmp main_loop

bler_and_loop:
ldi r22, 'e'
ldi r23, 'r'
rcall uart_blrep
rjmp main_loop


test_blpg:  
  rcall uart_read 
  cpi r16, 'G'
  brne test_b
  
  rcall uart_read

  cpi r18, state_enter // Если не был выполнен BLST, то - ошибка
  breq blpg_skip
  cpi r16, PAGES_AVAILABLE
  brsh blpg_skip
  cp r16, r3           // Если номер страницы не совпадает с ожидаемой - ошибка
  breq blpg_state_ok
    blpg_skip:
    ldi r17, PAGESIZE * 2 - 1 // скипается на 2 байта меньше, чем длина данных страницы. На случай если байт был потерян при доставке, к моменту следующего пакета парсер будет в состоянии ожидания
    blpg_skip_loop:
    rcall uart_read
    dec r17
    brne blpg_skip_loop
    rjmp bler_and_loop

  blpg_state_ok:

  .if PAGESIZE == 128
    mov r31, r16
    clr r30
  .else
    ldi r19, (PAGESIZE * 2)
    mul r16, r19
    movw r30, r0
  .endif
  ldi r19, PAGESIZE

  ldi r20, 0xFF

  // Загрузка страницы в страничный буфер
  blpg_load_loop:
    clr r28
    rcall uart_read_crc
	  mov r0, r16
	  rcall uart_read_crc
    .ifdef UCSR0A
      andi r28, (1 << FE0) | (1 << DOR0) | (1 << UPE0)
    .else
      andi r28, (1 << FE) | (1 << DOR) | (1 << UPE)
    .endif
    brne bler_and_loop // Если нет стоп-бита, или ошибка бита чётности, или пропущен байт, прерываем чтение страницы
	  mov r1, r16
	  ldi r16, (1 << SPMEN)
	  rcall do_spm
	  adiw r30, 2
	  dec r19
  brne blpg_load_loop
  // Проверка контрольной суммы
  rcall uart_read_crc 
  tst r20
  brne bler_and_loop

  cpi r18, state_flashing
  breq blpg_state_continue
    // Если только начали прошивку, то устанавливаем маркер 
    ldi r18, state_flashing
    .ifdef MAGIC
      ldi r16, 0xFF
      rcall write_magic
    .endif
    .if BLINKER == 1
      ldi r27, BLINKER_PATTERN_FLASHING
    .endif
  blpg_state_continue:

  // Стираем страницу из флеш и загружаем новую
  subi r30, low(PAGESIZE * 2)
  sbci r31, high(PAGESIZE * 2)

  ldi r16, (1 << PGERS) | (1 << SPMEN)
  rcall do_spm
  
  ldi r16, (1 << PGWRT) | (1 << SPMEN)
  rcall do_spm


  ldi r22, 'p'
  ldi r23, 'g'
  rcall uart_blrep
  mov r16, r3
  rcall uart_write
  inc r3 // Увеличиваем счётчик страниц

  rjmp main_loop

.ifdef MAGIC

// Загружает в EEARH:EEARL адрес MAGIC
// использует r17
load_magic_eear:
  ldi r17, high(MAGIC_EEPROM_ADDRESS)
  out EEARH, r17
  ldi r17, low(MAGIC_EEPROM_ADDRESS);
  out EEARL, r17
  ret

// r16 - сохраняемое значение
// использует r17
write_magic:
  rcall load_magic_eear
  out EEDR, r16
  .ifdef EEMWE
    sbi EECR, EEMWE
    sbi EECR, EEWE
  .else
    sbi EECR, EEMPE
    sbi EECR, EEPE
  .endif
 // сразу проваливаемся на ожидание окончания записи
.endif
wait_eeprom_finish:
  .ifdef EEWE
    sbic EECR, EEWE
  .else
    sbic EECR, EEPE
  .endif
  rjmp wait_eeprom_finish
ret

// Чтение из UART
// Ожидает байт и возвращает его в r16
// Увеличивает значение r26:r25:r24 и применяет мигание (из регистра r27) 
uart_read:
  .if BLINKER == 1
    .ifdef UCSR0A
      lds r16, UCSR0A
      sbrc r16, RXC0
    .else
      sbic UCSRA, RXC
    .endif
    rjmp uart_do_read
    sbiw r24, 1
    brne uart_read
    inc r26
    mov r16, r26
    and r16, r27
    brne uart_read_clear_blinker
      sbi BLINKER_PORT, BLINKER_PIN_NUM
      rjmp uart_read
    uart_read_clear_blinker:
      cbi BLINKER_PORT, BLINKER_PIN_NUM
      rjmp uart_read
  .else
    .ifdef UCSR0A
      lds r16, UCSR0A
      sbrs r16, RXC0
    .else
      sbis UCSRA, RXC
    .endif
    rjmp uart_read
  .endif
 uart_do_read:
  .ifdef UCSR0A
    lds r16, UCSR0A
    or r28, r16
    lds r16, UDR0
  .else
    in r16, UCSRA
    or r28, r16
    in r16, UDR
  .endif
ret

// Чтение из UART и обновление контрольной суммы
// Вызывает uart_read, который ожидает байт и возвращает его в r16, увеличивает значение r26:r25:r24 и применяет мигание (из регистра r27) 
// Прочитанным значением обновляется контрольная сумма в регистре r20
// Использует r22, r23
uart_read_crc:
  rcall uart_read
  eor r20, r16
  ldi r22, 8
  ldi r23, 0xCF
  crc_loop:
    lsl r20
    brcc crc_no_xor
      eor r20, r23
    crc_no_xor:
    dec r22
  brne crc_loop
    
ret 

  

// Запись в UART
// r16 - передаваемый байт
// Использует r17

uart_write:
  .ifdef UCSR0A
    lds r17, UCSR0A
    sbrs r17, UDRE0
    rjmp uart_write
    sts UDR0, r16
  .else
    sbis UCSRA, UDRE
    rjmp uart_write
    out UDR, r16
  .endif
ret

uart_blrep:
  ldi r16, 'b'
  rcall uart_write
  ldi r16, 'l'
  rcall uart_write
  mov r16, r22
  rcall uart_write
  mov r16, r23
rjmp uart_write


do_spm: // на входе в r16 - значение SPMCSR
  .ifdef SPMCR
    out SPMCR, r16
    spm
    wait_spm:
    in r17, SPMCR
    sbrc r17, SPMEN
    rjmp wait_spm
  .else
    out SPMCSR, r16
    spm
    wait_spm:
    in r17, SPMCSR
    sbrc r17, SPMEN
    rjmp wait_spm
  .endif
ret

// Очищает регистры портов
// На выходе r16 == 0
clear_ports:
  clr r16
  .if (defined(PORTE) && (PC > (FLASHEND - 24))) // Если у нас слишком дофига портов, а памяти уже не осталось...
     // ...то обнулим только те порты, которые используются загрузчиком
    .if BLINKER == 1 
      out BLINKER_DDR, r16
      out BLINKER_PORT, r16
    .endif
    .ifdef FORCE_METHOD
       out FORCE_DDR, r16
       out FORCE_PORT, r16
      .if FORCE_METHOD >= 3 
         out FORCE_DDR2, r16
         out FORCE_PORT2, r16
      .endif
    .endif
  .else 
    // Если есть куда плясать - обнулим все порты
    .ifdef PORTA
      out DDRA, r16
      out PORTA, r16
    .endif
    .ifdef PORTB
      out DDRB, r16
      out PORTB, r16
    .endif
    .ifdef PORTC
      out DDRC, r16
      out PORTC, r16
    .endif
    .ifdef PORTD
      out DDRD, r16
      out PORTD, r16
    .endif
    .ifdef PORTE
      out DDRE, r16
      out PORTE, r16
    .endif
    .ifdef PORTF
      out DDRF, r16
      out PORTF, r16
    .endif
    .ifdef PORTG
      out DDRG, r16
      out PORTG, r16
    .endif
  .endif
ret

// bootloader_id возвращается в ответе на команду BLST, содержит ровно 16 байт. Первые два байта - размер страницы (в словах) и количество доступных страниц
// bootloader_id is being returned in reply to BLST, contains exactly 16 bytes. First two bytes are: page size (in words) and number of pages available
bootloader_id: 
  .db  PAGESIZE, PAGES_AVAILABLE, HARDWARE_ID




