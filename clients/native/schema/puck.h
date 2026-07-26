// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.8
// 
#ifndef __SCHEMA_CODEGEN_PUCK_H__
#define __SCHEMA_CODEGEN_PUCK_H__ 1

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
} puck_t;

static const colyseus_field_t puck_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(puck_t, x), NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(puck_t, y), NULL, NULL},
    {2, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(puck_t, vx), NULL, NULL},
    {3, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(puck_t, vy), NULL, NULL}
};

static puck_t* puck_create(void) {
    puck_t* instance = calloc(1, sizeof(puck_t));
    return instance;
}

static void puck_destroy(colyseus_schema_t* schema) {
    puck_t* instance = (puck_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t puck_vtable = {
    "Puck",
    sizeof(puck_t),
    (colyseus_schema_t* (*)(void))puck_create,
    puck_destroy,
    puck_fields,
    4
};

#endif
