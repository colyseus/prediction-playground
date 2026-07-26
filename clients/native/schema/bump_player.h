// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.8
// 
#ifndef __SCHEMA_CODEGEN_BUMPPLAYER_H__
#define __SCHEMA_CODEGEN_BUMPPLAYER_H__ 1

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
    uint8_t bumpTicks;
    uint16_t bumps;
} bump_player_t;

static const colyseus_field_t bump_player_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(bump_player_t, x), NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(bump_player_t, y), NULL, NULL},
    {2, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(bump_player_t, vx), NULL, NULL},
    {3, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(bump_player_t, vy), NULL, NULL},
    {4, "hue", COLYSEUS_FIELD_UINT8, "uint8", offsetof(bump_player_t, hue), NULL, NULL},
    {5, "bumpTicks", COLYSEUS_FIELD_UINT8, "uint8", offsetof(bump_player_t, bumpTicks), NULL, NULL},
    {6, "bumps", COLYSEUS_FIELD_UINT16, "uint16", offsetof(bump_player_t, bumps), NULL, NULL}
};

static bump_player_t* bump_player_create(void) {
    bump_player_t* instance = calloc(1, sizeof(bump_player_t));
    return instance;
}

static void bump_player_destroy(colyseus_schema_t* schema) {
    bump_player_t* instance = (bump_player_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t bump_player_vtable = {
    "BumpPlayer",
    sizeof(bump_player_t),
    (colyseus_schema_t* (*)(void))bump_player_create,
    bump_player_destroy,
    bump_player_fields,
    7
};

#endif
