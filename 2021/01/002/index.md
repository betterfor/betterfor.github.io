# LEETCODE 002. 


众所周知啊，链表题是题库一个比较大的分类。那么今天我们开始解决第一道链表题。

那么什么是链表呢？

```go
type ListNode struct {
	Val  int
	Next *ListNode
}
```
我们通常把这种结构成为链表。

那么链表有什么样的特点呢？
- 顺序存储结构
- 插入和删除只能修改指针，不能随机存取

---

那么来看看今天的题~

给出两个 **非空** 的链表用来表示两个非负的整数。
其中，它们各自的位数是按照 **逆序** 的方式存储的，并且它们的每个节点只能存储 **一位** 数字。

如果，我们将这两个数相加起来，则会返回一个新的链表来表示它们的和。

可能看到这里会感觉到云里雾里，来看看一个示例：

<pre><strong>输入：</strong>(2 -&gt; 4 -&gt; 3) + (5 -&gt; 6 -&gt; 4)
<strong>输出：</strong>7 -&gt; 0 -&gt; 8
</pre>

这样一看是不是就很清晰明了了。

也就是说我们只要按照链表的顺序相加，如果和大于10，需要进位，所以我们需要一个数 `carry` 来保存进位数。

```go
func addTwoNumbers(l1, l2 *ListNode) *ListNode {
	var head = new(ListNode)
	current := head
	var carry int
	for l1 != nil || l2 != nil {
		var x, y int
		if l1 != nil {
			x = l1.Val
		}
		if l2 != nil {
			y = l2.Val
		}
		current.Next = &ListNode{Val: (x + y + carry) % 10, Next: nil}
		current = current.Next
		carry = (x + y + carry) / 10
		if l1 != nil {
			l1 = l1.Next
		}
		if l2 != nil {
			l2 = l2.Next
		}
	}
	if carry > 0 {
		current.Next = &ListNode{Val: carry % 10}
	}
	return head.Next
}
```

可能有同学要问了，为什么不用current而用head呢？

这是因为current跟随链表一直向后移动，已经到达最后了，而head是真的head，通过这种指针结构保存了首位地址。

![002-01](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/28/002-01.png)