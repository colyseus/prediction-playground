// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RANGEINPUT_H__
#define __SCHEMA_CODEGEN_RANGEINPUT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    int8_t moveX;
    int8_t moveY;
    float aimX;
    float aimY;
    bool fire;
    bool spread;
} range_input_t;

static const colyseus_field_t range_input_fields[] = {
    {0, "moveX", COLYSEUS_FIELD_INT8, "int8", offsetof(range_input_t, moveX), NULL, NULL, NULL},
    {1, "moveY", COLYSEUS_FIELD_INT8, "int8", offsetof(range_input_t, moveY), NULL, NULL, NULL},
    {2, "aimX", COLYSEUS_FIELD_FLOAT32, "float32", offsetof(range_input_t, aimX), NULL, NULL, NULL},
    {3, "aimY", COLYSEUS_FIELD_FLOAT32, "float32", offsetof(range_input_t, aimY), NULL, NULL, NULL},
    {4, "fire", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(range_input_t, fire), NULL, NULL, NULL},
    {5, "spread", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(range_input_t, spread), NULL, NULL, NULL}
};

static range_input_t* range_input_create(void) {
    range_input_t* instance = calloc(1, sizeof(range_input_t));
    return instance;
}

static void range_input_destroy(colyseus_schema_t* schema) {
    range_input_t* instance = (range_input_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t range_input_vtable = {
    "RangeInput",
    sizeof(range_input_t),
    (colyseus_schema_t* (*)(void))range_input_create,
    range_input_destroy,
    range_input_fields,
    6
};

#endif
