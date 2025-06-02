return {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
	config = function ()
		local harpoon = require("harpoon")

		harpoon:setup()

		vim.keymap.set("n", "<leader>ha", function() harpoon:list():add() end, {desc = "[H]arpoon [A]dd"})
		vim.keymap.set("n", "<leader>hm", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, {desc = "[H]arpoon [M]enu"})

		vim.keymap.set("n", "<leader>h1", function() harpoon:list():select(1) end, { desc = "[H]arpoon 1"})
		vim.keymap.set("n", "<leader>h2", function() harpoon:list():select(2) end, { desc = "[H]arpoon 2"})
		vim.keymap.set("n", "<leader>h3", function() harpoon:list():select(3) end, { desc = "[H]arpoon 3"})
		vim.keymap.set("n", "<leader>h4", function() harpoon:list():select(4) end, { desc = "[H]arpoon 4"})

		vim.keymap.set("n", "<leader>hh", function() harpoon:list():prev() end, { desc = "[H]arpoon previos"})
		vim.keymap.set("n", "<leader>hl", function() harpoon:list():next() end, { desc = "[H]arpoon next"})
	end
}
