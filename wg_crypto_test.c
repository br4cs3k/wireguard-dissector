/**
 * Tests for wg_crypto.
 * Copyright (C) 2018 Peter Wu <peter@lekensteyn.nl>
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "wg_crypto.h"

// {{{ Test packets
static unsigned char pkt_wg_initiation[] = {
  0x01, 0x00, 0x00, 0x00, 0x15, 0xcf, 0x47, 0xc7, 0x74, 0x4f, 0xc5, 0x7d,
  0x33, 0x64, 0x2a, 0x1c, 0xa5, 0x16, 0xfd, 0x83, 0x62, 0xa6, 0xfb, 0x90,
  0x8e, 0x4f, 0xdc, 0x04, 0x65, 0x49, 0xd8, 0x0f, 0xaa, 0xa3, 0x70, 0x4b,
  0x68, 0xc7, 0xcb, 0x73, 0xac, 0x70, 0x7e, 0x42, 0xe7, 0x63, 0x6c, 0xfb,
  0x87, 0xfd, 0x4d, 0x75, 0x5d, 0x68, 0x69, 0x4d, 0xf1, 0x75, 0x6f, 0xe4,
  0x08, 0x9a, 0x57, 0x40, 0xdf, 0x78, 0x72, 0x31, 0x04, 0x26, 0xd4, 0x34,
  0xed, 0x38, 0x4a, 0x75, 0x39, 0x35, 0x19, 0x8b, 0x27, 0x7a, 0x6d, 0x86,
  0x5a, 0x4a, 0x59, 0x7d, 0x1a, 0x15, 0x9f, 0x8b, 0xea, 0x3e, 0x20, 0xb4,
  0x46, 0x53, 0x99, 0xfb, 0xe6, 0xf2, 0x60, 0x2f, 0xa6, 0xb6, 0x57, 0xa8,
  0x89, 0x6a, 0xd6, 0x44, 0x36, 0x09, 0xcf, 0xd6, 0xd0, 0x27, 0xf0, 0x41,
  0xb4, 0xca, 0xe1, 0x01, 0x6f, 0x43, 0x51, 0x57, 0x03, 0x7f, 0x0e, 0xa9,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00
};
static unsigned int pkt_wg_initiation_len = 148;

static unsigned char pkt_wg_responder[] = {
  0x02, 0x00, 0x00, 0x00, 0x32, 0xfa, 0x1a, 0xac, 0x15, 0xcf, 0x47, 0xc7,
  0x19, 0x3c, 0xbb, 0x31, 0x1b, 0x41, 0x32, 0x23, 0x5f, 0xe1, 0x78, 0xaf,
  0x86, 0x2f, 0xc6, 0x7d, 0x31, 0x12, 0x2a, 0xbc, 0x0f, 0x08, 0x0e, 0xfa,
  0xfc, 0x5e, 0xa2, 0x7a, 0x9a, 0x94, 0xa1, 0x07, 0x50, 0xf4, 0x09, 0x20,
  0xef, 0x17, 0x86, 0xe0, 0x49, 0x47, 0x2e, 0x8b, 0x03, 0x59, 0x5e, 0x65,
  0x73, 0x0b, 0x94, 0xf1, 0x3b, 0x49, 0xd2, 0x94, 0xbf, 0x85, 0xf5, 0xca,
  0xd7, 0xf6, 0xef, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
static unsigned int pkt_wg_responder_len = 92;
/// }}}

// {{{ Secrets: local Spriv / remote Spub / local Epriv / PSK
static const char *initiator_secrets[] = {
    "gBen0g0RVUOR4ehlFkWdDf18Ic//lxBIxa1PqvjTmEw=",
    "JRI8Xc0zKP9kXk8qP84NdUQA04h6DLfFbwJn4g+/PFs=",
    "wGygl2kFYdbJWIMtEmaSQAMONuX1+b2EZ9umhB6mCEo=",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
};

static const char *responder_secrets[] = {
    "QChaGDXeH3eQsbFAhueUNWFdq9KfpF3yl+eITjZbXEk=",
    "eKSmoueAzZ+0cLTiix9F+Hcu5X0VvTXlsNPGGwFwiS4=",
    "ELwhlhseNwg64Fos0qJhXbSVeBc2lYVkqdmkLx3rekg=",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
};
// }}}

int main()
{
    wg_qqword   Spub_i = { 0 };
    wg_tai64n_t timestamp = { 0 };
    wg_tai64n_t timestamp_expected = {
        0x40, 0x00, 0x00, 0x00,
        0x5a, 0x99, 0x4d, 0x2c, 0x3b, 0x38, 0x94, 0x69
    };
    gboolean    r;
    wg_keys_t   initiator_keys, responder_keys;
    wg_qqword   initiator_h, initiator_ck;
    wg_qqword   responder_h, responder_ck;
    wg_qqword  *Epub_i = (wg_qqword *)(pkt_wg_initiation + 8);
    gcry_cipher_hd_t cipher_i, cipher_r;

    if (!gcry_check_version(NULL)) {
        g_assert_not_reached();
    }

    r = wg_decrypt_init();
    g_assert(r);

    r = wg_process_keys(&initiator_keys, initiator_secrets[0], initiator_secrets[1], initiator_secrets[2], initiator_secrets[3]);
    g_assert(r);
    r = wg_process_keys(&responder_keys, responder_secrets[0], responder_secrets[1], responder_secrets[2], responder_secrets[3]);
    g_assert(r);

    r = wg_check_mac1(pkt_wg_initiation, pkt_wg_initiation_len, &initiator_keys.receiver_mac1_key);
    g_assert(r);
    r = wg_check_mac1(pkt_wg_initiation, pkt_wg_initiation_len, &responder_keys.sender_mac1_key);
    g_assert(r);

    r = wg_check_mac1(pkt_wg_responder, pkt_wg_responder_len, &responder_keys.receiver_mac1_key);
    g_assert(r);
    r = wg_check_mac1(pkt_wg_responder, pkt_wg_responder_len, &initiator_keys.sender_mac1_key);
    g_assert(r);

    r = wg_process_initiation(pkt_wg_initiation, pkt_wg_initiation_len, &initiator_keys, TRUE, &Spub_i, &timestamp, &initiator_h, &initiator_ck);
    g_assert(r);
    g_assert(memcmp(Spub_i, initiator_keys.sender_static.public_key, sizeof(Spub_i)) == 0);
    g_assert(memcmp(timestamp, timestamp_expected, sizeof(timestamp)) == 0);

    r = wg_process_initiation(pkt_wg_initiation, pkt_wg_initiation_len, &responder_keys, FALSE, &Spub_i, &timestamp, &responder_h, &responder_ck);
    g_assert(r);
    g_assert(memcmp(Spub_i, responder_keys.receiver_static_public, sizeof(Spub_i)) == 0);
    g_assert(memcmp(timestamp, timestamp_expected, sizeof(timestamp)) == 0);

    /* should reach same state after processing initiation message */
    g_assert(memcmp(initiator_h, responder_h, sizeof(initiator_h)) == 0);
    g_assert(memcmp(initiator_ck, responder_ck, sizeof(initiator_ck)) == 0);

    cipher_i = cipher_r = NULL;
    r = wg_process_response(pkt_wg_responder, pkt_wg_responder_len, &initiator_keys, TRUE, Epub_i, &initiator_h, &initiator_ck, &cipher_i, &cipher_r);
    g_assert(r);
    g_assert(cipher_i);
    g_assert(cipher_r);
    gcry_cipher_close(cipher_i);
    gcry_cipher_close(cipher_r);

    cipher_i = cipher_r = NULL;
    r = wg_process_response(pkt_wg_responder, pkt_wg_responder_len, &responder_keys, FALSE, Epub_i, &responder_h, &responder_ck, &cipher_i, &cipher_r);
    g_assert(r);
    g_assert(cipher_i);
    g_assert(cipher_r);
    gcry_cipher_close(cipher_i);
    gcry_cipher_close(cipher_r);

    return 0;
}
