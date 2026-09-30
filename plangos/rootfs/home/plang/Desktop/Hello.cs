using System;

namespace PlangOS.Samples;

/// <summary>A greeting, the way C# says it.</summary>
public static class Hello
{
    // how many times it has greeted
    private static int count;

    public static string Greet(string name)
    {
        count++;
        return $"Halló, {name}! ({count})";
    }

    public static void Main()
    {
        Console.WriteLine(Greet("PlangOS"));
    }
}
