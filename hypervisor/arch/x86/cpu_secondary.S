/*
 * Copyright (C) 2018 Intel Corporation. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 *   * Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   * Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in
 *     the documentation and/or other materials provided with the
 *     distribution.
 *   * Neither the name of Intel Corporation nor the names of its
 *     contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include        <hypervisor.h>
#include        <spinlock.h>
#include        <gdt.h>
#include        <cpu.h>
#include        <mmu.h>
#include        <msr.h>


    .extern     cpu_secondary_init
    .extern     cpu_logical_id
    .extern     _ld_bss_end
    .extern     HOST_GDTR

    .section     .cpu_secondary_reset,"ax"

   .align   4
   .code16
   .global      cpu_secondary_reset
   .org 0
cpu_secondary_reset:

    /* Disable local interrupts */

    cli
    mov %cs, %ax
    mov %ax, %ds

    /* Set DE, PAE, MCE and OS support bits in CR4 */

    movl    $(CR4_DE | CR4_PAE | CR4_MCE | CR4_OSFXSR | CR4_OSXMMEXCPT), %eax
    mov     %eax, %cr4

    /* Set CR3 to PML4 table address */

    movl    $CPU_Boot_Page_Tables_ptr, %ebx
    mov     (%ebx), %eax
    mov     %eax, %cr3

    /* Set LME bit in EFER */

    movl    $MSR_IA32_EFER, %ecx
    rdmsr
    orl     $MSR_IA32_EFER_LME_BIT, %eax
    wrmsr

    /* Enable paging, protection, numeric error and co-processor
       monitoring in CR0 to enter long mode */

    mov     %cr0, %ebx
    orl     $(CR0_PG | CR0_PE | CR0_MP | CR0_NE), %ebx
    mov     %ebx, %cr0

    /* Load temportary GDT pointer value */
    lgdt    (cpu_secondary_gdt_ptr - cpu_secondary_reset)

    /* Perform a long jump based to start executing in 64-bit mode */

    movl    $ap_long_mode_jump_ref, %ebx
    ljmpl   *(%ebx)

    .align 8
    .global ap_long_mode_jump_ref
ap_long_mode_jump_ref:
    .long   cpu_secondary_long_mode
    .word   HOST_GDT_RING0_CODE_SEL

    .code64
cpu_secondary_long_mode:

    /* Set up all other data segment registers */

    movl    $HOST_GDT_RING0_DATA_SEL, %eax
    mov     %eax, %ss
    mov     %eax, %ds
    mov     %eax, %es
    mov     %eax, %fs
    mov     %eax, %gs

    /* Obtain secondary CPU spin-lock to serialize
       booting of secondary cores for a bit */

    mov     $cpu_secondary_spinlock, %rdi
    spinlock_obtain(%rdi)

    /* Initialize temporary stack pointer
       NOTE:  Using the PML4 memory (PDPT address is top of memory
              for the PML4 page) for the temporary stack
              as we are only using the very first entry in
              this page and the stack is growing down from
              the top of this page.  This stack is only
              used for a VERY short period of time, so
              this reuse of PML4 memory should be acceptable. */
    lea     cpu_secondary_pdpt_addr(%rip), %rsp

    /* Push sp magic to top of stack for call trace */
    pushq   $SP_BOTTOM_MAGIC

    /* Jump to C entry for the AP */

    mov     $cpu_secondary_init, %rax
    jmp     *%rax

/* GDT table */
    .align  4
cpu_secondary_gdt:
    .quad   0x0000000000000000
    .quad   0x00af9b000000ffff
    .quad   0x00cf93000000ffff
cpu_secondary_gdt_end:

/* GDT pointer */
    .align  2
    .global cpu_secondary_gdt_ptr
cpu_secondary_gdt_ptr:
    .short  (cpu_secondary_gdt_end - cpu_secondary_gdt) - 1
    .quad   cpu_secondary_gdt

/* PML4, PDPT, and PD tables initialized to map first 4 GBytes of memory */
    .align  4
    .global CPU_Boot_Page_Tables_ptr
CPU_Boot_Page_Tables_ptr:
    .long CPU_Boot_Page_Tables_Start

    .align  CPU_PAGE_SIZE
    .global CPU_Boot_Page_Tables_Start
CPU_Boot_Page_Tables_Start:
    .quad   cpu_secondary_pdpt_addr + (IA32E_COMM_P_BIT | IA32E_COMM_RW_BIT)
    .align  CPU_PAGE_SIZE
    .global cpu_secondary_pdpt_addr
cpu_secondary_pdpt_addr:
    address = 0
    .rept   4
    .quad   cpu_secondary_pdt_addr + address + \
                                        (IA32E_COMM_P_BIT | IA32E_COMM_RW_BIT)
    address = address + CPU_PAGE_SIZE
    .endr
    .align  CPU_PAGE_SIZE
cpu_secondary_pdt_addr:
    address = 0
    .rept  2048
    .quad  address + (IA32E_PDPTE_PS_BIT | IA32E_COMM_P_BIT | IA32E_COMM_RW_BIT)
    address = address + 0x200000
    .endr

    .end
