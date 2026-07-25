// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RANGEPLAYER_H__
#define __SCHEMA_CODEGEN_RANGEPLAYER_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double y;
    double vx;
    double vy;
    uint8_t hue;
    uint16_t shots;
    uint16_t hits;
} range_player_t;

static const colyseus_field_t range_player_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(range_player_t, x), NULL, NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(range_player_t, y), NULL, NULL, NULL},
    {2, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(range_player_t, vx), NULL, NULL, NULL},
    {3, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(range_player_t, vy), NULL, NULL, NULL},
    {4, "hue", COLYSEUS_FIELD_UINT8, "uint8", offsetof(range_player_t, hue), NULL, NULL, NULL},
    {5, "shots", COLYSEUS_FIELD_UINT16, "uint16", offsetof(range_player_t, shots), NULL, NULL, NULL},
    {6, "hits", COLYSEUS_FIELD_UINT16, "uint16", offsetof(range_player_t, hits), NULL, NULL, NULL}
};

static range_player_t* range_player_create(void) {
    range_player_t* instance = calloc(1, sizeof(range_player_t));
    return instance;
}

static void range_player_destroy(colyseus_schema_t* schema) {
    range_player_t* instance = (range_player_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t range_player_vtable = {
    "RangePlayer",
    sizeof(range_player_t),
    (colyseus_schema_t* (*)(void))range_player_create,
    range_player_destroy,
    range_player_fields,
    7
};

#endif
