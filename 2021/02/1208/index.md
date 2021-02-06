# LEETCODE 1208. 尽可能使字符串相等


大家好，我是沉迷于刷题的小耗。

今天给大家带来的是力扣1208题：**尽可能使字符串相等**

## 题目

给你两个长度相同的字符串，`s`和`t`。

将`s`中的第`i`个字符变到`t`中的第`i`个字符需要`|s[i]-t[i]|`的开销(开销可能为0)，也就是两个字符的ASCII码值的差的绝对值。

用于变更字符串的最大预算是`maxCount`。在转化字符串时，总开销应当小于等于该预算，这也意味着字符串转化可能是不完全的。

如果你可以将`s`的子字符串转化为它在`t`中对应的子字符串，则返回可以转化的最大长度。

## 示例

**输入**：s = "abcd", t = "bcdf", cost = 3
**输出**：3
**解释**：s 中的 "abc" 可以变为 "bcd"。开销为 3，所以最大长度为 3。

## 题解

先理解一下题意，s和t是在相同位置上的字符进行比较，`|s[i]-t[i]|`为一位上的开销，那么我们可以得到每一位的开销。而要从s和t找到一个子串，使得子串的开销之和小于最大开销，并使得子串的长度最长。

### 二分法

```go
func equalSubstring(s string, t string, maxCost int) (ans int) {
	n := len(s)
	diff := make([]int,n+1) // 递增序列
	for i, ch := range s {
		diff[i+1] = diff[i]+abs(int(ch)-int(t[i]))
	}
	for i := 1; i <= n; i++ {
		start := sort.SearchInts(diff[:i],diff[i]-maxCost)
		ans = max(ans,i-start)
	}
	return
}

func abs(a int) int {
	if a < 0 {
		return -a
	}
	return a
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
```

在一个递增序列，通过二分查找的方式，在下标范围[0,i]内找到最小的下标start，使得diff[start]>=diff[i]-maxCost，那么此时对应的diff的子数组的下标范围是[start:i-1]，子数组的长度是i-start。

时间复杂度O(nlogn),空间复杂度O(n)

这里用到了一个二分查找的Search方法。

```go
func SearchInts(a []int, x int) int {
	return Search(len(a), func(i int) bool { return a[i] >= x })
}

func Search(n int, f func(int) bool) int {
	// Define f(-1) == false and f(n) == true.
	// Invariant: f(i-1) == false, f(j) == true.
	i, j := 0, n
	for i < j {
		h := int(uint(i+j) >> 1) // avoid overflow when computing h
		// i ≤ h < j
		if !f(h) {
			i = h + 1 // preserves f(i-1) == false
		} else {
			j = h // preserves f(j) == true
		}
	}
	// i == j, f(i-1) == false, and f(j) (= f(i)) == true  =>  answer is i.
	return i
}
```

### 双指针

维护两个指针表示数组的子数组的开始下标和结束下标，满足子数组的元素之和不超过maxCost。

```go
func equalSubstring(s string, t string, maxCost int) (ans int) {
	n := len(s)
	diff := make([]int,n)
	for i, ch := range s {
		diff[i] = abs(int(ch)-int(t[i]))
	}
	var sum, left int
	for i, d := range diff {
		sum+=d
		for sum > maxCost {
			sum-=diff[left]
			left++
		}
		ans = max(ans,i-left+1)
	}
	return
}

func abs(a int) int {
	if a < 0 {
		return -a
	}
	return a
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
```

时间复杂度O(n)，空间复杂度O(n)

