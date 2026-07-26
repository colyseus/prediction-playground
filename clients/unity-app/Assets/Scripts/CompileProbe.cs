using Colyseus;
using UnityEngine;

// Smoke file: proves the SDK package resolves and the predict layer is visible.
public static class CompileProbe
{
    public static string Describe() => typeof(Colyseus.Predict).FullName + " / " + typeof(ColyseusClient).FullName;
}
