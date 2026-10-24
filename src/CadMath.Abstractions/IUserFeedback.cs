using System;

namespace CadMath.Abstractions;

/// <summary>
/// 适配器把"发生了什么"告诉宿主，用于给用户即时反馈。
/// 实现方负责决定怎么展示（写命令行、状态栏、什么都不做）；适配器不直接碰编辑器 API。
/// </summary>
public interface IUserFeedback
{
    /// <summary>一次改写成功：<paramref name="original"/> 被换成了 <paramref name="value"/>。</summary>
    void OnReplaced(string original, string value);

    /// <summary>一次输入被拒绝：<paramref name="code"/> 是 ErrorCodes，<paramref name="message"/> 是给用户看的中文原因。</summary>
    void OnRejected(string original, string code, string message);
}
