/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* mini-xv6's USB host controller: the DWC2 (Synopsys DesignWare Hi-Speed
 * USB 2.0 OTG) of both boards (the Pi1's, the Pi4's second controller,
 * which QEMU's raspi4b models too), at the peripherals' 0x980000. What
 * OCaml cannot say: its registers use bits 31 and 30 (a channel's
 * enable, the SETUP PID), past the Pi1's OCaml ints. So the protocol is
 * Usbhost.ml's, and here only the controller's two operations: the host
 * started (the root port powered and reset), and one transfer, on
 * channel 0, polled to its end, through a DMA page OCaml fills and reads
 * (Phys, at usb_buffer's physical address).
 *
 * References: the DWC2's registers as QEMU's hw/usb/hcd-dwc2.h names
 * them (read 2026-09-25); CSUD, xv6 arm-pi1's USB driver, for the
 * order of the steps. */

#include <mlvalues.h>
#include "board.h"

void delay_us(unsigned us);

#define USB(off) (*(volatile unsigned *)(IO_BASE + 0x980000UL + (off)))

#define GAHBCFG 0x008
#define HPRT 0x440
#define HCCHAR(ch) (0x500 + 0x20 * (ch))
#define HCINT(ch) (0x508 + 0x20 * (ch))
#define HCINTMSK(ch) (0x50c + 0x20 * (ch))
#define HCTSIZ(ch) (0x510 + 0x20 * (ch))
#define HCDMA(ch) (0x514 + 0x20 * (ch))

/* HPRT: the bits a write clears when 1 (connect detected, enabled,
 * enable changed, over-current changed), kept 0 when writing others */
#define HPRT_W1C 0x2e
#define HPRT_POWER (1 << 12)
#define HPRT_RESET (1 << 8)
#define HPRT_ENABLED (1 << 2)
#define HPRT_CONNECTED (1 << 0)

/* the DMA page: the transfers' data */
static unsigned char buffer[4096] __attribute__((aligned(4096)));

value usb_buffer(value unit) { (void)unit; return Val_long((unsigned long)buffer - KERNBASE); }

/* the host started: DMA on, the root port powered, then reset (50ms, as
 * USB wants) and enabled; whether a device is there */
value usb_init(value unit)
{
  unsigned p;
  (void)unit;
  USB(GAHBCFG) |= 1 << 5;                                  /* DMA */
  p = USB(HPRT) & ~HPRT_W1C;
  USB(HPRT) = p | HPRT_POWER;
  delay_us(20000);
  p = USB(HPRT) & ~HPRT_W1C;
  USB(HPRT) = p | HPRT_RESET;
  delay_us(50000);
  p = USB(HPRT) & ~HPRT_W1C;
  USB(HPRT) = p & ~HPRT_RESET;
  delay_us(20000);
  return Val_bool((USB(HPRT) & (HPRT_CONNECTED | HPRT_ENABLED)) == (HPRT_CONNECTED | HPRT_ENABLED));
}

/* one transfer of [len] bytes from or to the DMA page: [desc] packs the
 * device's address (bits 0-6), the endpoint (7-10), its type (11-12:
 * 0 control, 3 interrupt), IN (13), low speed (14), the maximum packet
 * (16-26); [pid] 0 DATA0, 2 DATA1, 3 SETUP. The bytes moved, or -1 NAK,
 * -2 STALL, -3 an error or no answer */
value usb_transfer(value vdesc, value vpid, value vlen)
{
  unsigned desc = Long_val(vdesc), pid = Long_val(vpid), len = Long_val(vlen);
  unsigned addr = desc & 0x7f, ep = (desc >> 7) & 0xf, type = (desc >> 11) & 3;
  unsigned in = (desc >> 13) & 1, low = (desc >> 14) & 1, mps = (desc >> 16) & 0x7ff;
  unsigned pkts = len == 0 ? 1 : (len + mps - 1) / mps;
  unsigned i, hcint;
  USB(HCINT(0)) = 0xffffffff;
  USB(HCINTMSK(0)) = 0;                                    /* polled: the channel's interrupt never raised */
  USB(HCTSIZ(0)) = len | (pkts << 19) | (pid << 29);
  USB(HCDMA(0)) = (unsigned)(((unsigned long)buffer - KERNBASE + BUS_ALIAS) & 0xffffffffUL);
  USB(HCCHAR(0)) = mps | (ep << 11) | (in << 15) | (low << 17) | (type << 18) | (1 << 20) | (addr << 22);
  USB(HCCHAR(0)) |= 1u << 31;                              /* enabled: the transfer starts */
  for (i = 0; i < 1000000; i++) {
    hcint = USB(HCINT(0));
    if (hcint & 0x2) break;                                /* halted */
  }
  USB(HCINT(0)) = 0xffffffff;
  if (!(hcint & 0x2)) return Val_long(-3);
  if (hcint & 0x10) return Val_long(-1);                   /* NAK */
  if (hcint & 0x8) return Val_long(-2);                    /* STALL */
  if (!(hcint & 0x1)) return Val_long(-3);                 /* not complete: an error */
  return Val_long(len - (USB(HCTSIZ(0)) & 0x7ffff));
}
