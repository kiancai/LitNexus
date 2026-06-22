import Foundation

// 新工作区的默认模板内容，对应 Python 参考的 DEFAULT_* 常量。

enum Templates {
    static let defaultQuestions: [Question] = [
        Question(
            id: "q1",
            nickname: "生物医学领域",
            text: """
            请判断本文是否属于'计算生物学、生物信息学、生物医学'或相关交叉领域。\
            若文章属于以下任一类型，请回答'是'：(1) 涉及组学数据（基因/蛋白/代谢等）的分析或实验研究；\
            (2) 涉及生物算法、模型、软件工具或数据库的开发与应用；\
            (3) 对上述相关领域的综述、系统评价、进展总结或观点展望。\
            仅当文章是纯粹的临床护理个案、社会学调查、或完全不涉及生物医学背景的纯数学/计算机理论时，才回答'否'。
            """
        ),
        Question(
            id: "q2",
            nickname: "核心方向",
            text: """
            请判断本文是否属于以下任一核心关注领域（命中任意一项即回答'是'）：\
            (a) 微生物组学（Microbiome）；(b) 生物基础模型与生成式AI；(c) 生物医学机器学习应用；\
            (d) 病毒与病原体计算；(e) 生物信息核心工具。若均不属于，回答'否'。
            """
        ),
    ]

    static let defaultJournalsTxt = """
    # 每行一个期刊名，需与 Europe PMC 中的名称完全一致；# 开头为注释、空行忽略。
    # 下面是示例，请按需增删：
    Nature
    Bioinformatics
    Genome Biology
    Nucleic Acids Research

    """

    static let defaultKeywordsTxt = """
    # 每行一个 Europe PMC 检索式，支持布尔语法（AND/OR/NOT）与引号短语；# 开头为注释。
    # 下面是示例，请按需增删：
    (microbiome OR microbiota) AND "machine learning"
    "single cell" AND (deep learning OR neural network)

    """
}
