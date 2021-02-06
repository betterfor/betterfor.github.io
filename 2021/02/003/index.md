# LEETCODE 003. 无重复字符的最长子串


> 力扣百题系列

众所周知啊，字符串是力扣题比较大的一个分类。今天我们就来解决第一道字符串题。

## 题目

给定一个字符串，请你找出其中不含有重复字符的 **最长子串** 的长度。

先来考虑一下这道题要我们干什么？

首先抓住几个**关键字**：重复字符，最长子串。

首先子串是包括英文字母，数字，符号和空格组成的，在一个字符串中找一个小子串，这是不是符合滑动窗口的概念？

用一个例子来展示一下。

字符串`abcabcbb`,列举出最长子串

- 以`(a)bcabcbb`开始的最长子串为`(abc)abcbb`
- 以`a(b)cabcbb`开始的最长子串为`a(bca)bcbb`
- 以`ab(c)abcbb`开始的最长子串为`ab(cab)cbb`
- 以`abc(a)bcbb`开始的最长子串为`abc(abc)bb`
- 以`abca(b)cbb`开始的最长子串为`abca(bc)bb`
- 以`abcab(c)bb`开始的最长子串为`abcab(cb)b`
- 以`abcabc(b)b`开始的最长子串为`abcabc(b)b`
- 以`abcabcb(b)`开始的最长子串为`abcabcb(b)`

我们发现依次递增起始子串的位置，那么子串结束位置也是递增的。这是因为我们以字符串中的第`k`个字符作为起点，并且得到不包含重复子串的结束位置显然大于`k`。这样我们可以使用双指针法解决这个问题。

## 双指针法

1、暴力法

按照常规的做法是固定左指针，然后从左指针位置开始向右遍历，找到重复字符为止；然后再向右移动左指针。当然，我们会发现一些重复的字符会被不断访问。

```go
 func lengthOfLongestSubstring(s string) int {
 	var maxLen int
 	for i := 0; i < len(s); i++ {
 		for j := i + 1; j <= len(s); j++ {
 			if isUnique(s[i:j])  {
 				if len(s[i:j]) > maxLen {
 					maxLen = len(s[i:j])
 				}
 			} else { // 如果该子串重复，继续添加后续字符也还是不重复
 				break
 			}
 		}
 	}
 	return maxLen
 }
 
 func isUnique(s string) bool {
 	var m = make(map[int32]bool)
 	for _, vChar := range s {
 		if _, ok := m[vChar]; ok {
 			return false
 		}
 		m[vChar] = true
 	}
 	return true
 }
```

时间复杂度O(n^3^),空间复杂度O(min(n,m)),我们需要 O(k) 的空间来检查子字符串中是否有重复字符，其中 k 表示 Set 的大小。而 Set 的大小取决于字符串 n 的大小以及字符集/字母 m 的大小。

效率低下的原因：例如`abca`，当左指针在a时，查询到abc，当左指针在b时，又会重复访问`bc`,而这样的效率不高。

2、滑动窗口

如果我们将右指针停留在`c`上，那么左指针移动时，右指针尝试向右移动，如果没有重复的字符，就移动，如果有就不移动。

下面是具体做法：

- 使用两个指针表示子串的位置，其中左指针代表枚举子串的初始位置，右指针代表子串的无重复位置
- 在每一步操作时，我们移动左指针，然后再不断移动右指针，需要保证两个指针中间没有重复字符

```go
func lengthOfLongestSubstring(s string) (ans int) {
    var right = -1 // right 为-1时表示没有移动
    var m = map[byte]int{}
    for i := 0;i < len(s); i++ {
        if i != 0 {
            delete(m,s[i])
        }
        for right+1 < len(s) && m[s[right+1]] {
            m[s[right+1]]++
            right++
        }
        ans = max(ans,right-i+1)
    }
    return ans
}

func max(a,b int) int {
    if a > b {
        return a
    }
    return b
}
```

时间复杂度O(2n)=O(n),最坏情况，每个字符都访问一遍，即所有相同字符。

空间复杂度O(min(m,n))

3、优化滑动窗口

方法2最多需要执行`2n`个步骤，可以考虑记录上个字符出现的位置，也就是说将map的值利用起来。

```go
 func lengthOfLongestSubstring(s string) int {
 	var count = make(map[rune]int) // 存放字符的位置
 	var max int
 	left := 0
 	for k, v := range s {
 		if val, ok := count[v]; ok {
 			if left < val {
 				left = val
 			}
 		}
 		if max < k-left+1 {
 			max = k - left + 1
 		}
 		count[v] = k + 1 // 更新位置
 	}
 	return max
 }
```

时间复杂度O(n)，右索引会遍历字符串

空间复杂度O(m)，字符串的长度